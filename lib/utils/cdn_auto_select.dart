import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 自动选择最快 CDN
///
/// Ported from the CDN racing idea of
/// https://github.com/SukkaW/Make-Bilibili-Great-Than-Ever-Before :
/// every candidate CDN is asked for the first bytes of the video that is
/// currently playing, with a short time budget and limited concurrency, and
/// the fastest one is used for the next playbacks.
///
/// The test never blocks playback: it runs in the background after the play
/// url has been resolved, and only changes [VideoUtils.cdnService] when it
/// finishes. On any failure the current setting is kept.
abstract final class CdnAutoSelector {
  /// A ranking is reused for this long before the next playback tests again
  static const _ttl = Duration(hours: 6);

  /// Bytes asked from each CDN
  static const _sampleBytes = 1024 * 1024;

  /// Time budget for one CDN, connection included
  static const _perHostTimeout = Duration(seconds: 4);

  /// CDNs tested at the same time
  static const _concurrency = 4;

  static bool _running = false;

  /// CDNs that may be selected automatically.
  ///
  /// [CDNService.baseUrl] is excluded on purpose: it is usually a P2P CDN
  /// (mcdn / PCDN) and is marked as not recommended.
  static Iterable<CDNService> get candidates =>
      CDNService.values.where((e) => e != CDNService.baseUrl);

  static bool get _enabled => Pref.autoSelectCdn;

  static bool get _isFresh {
    final time = Pref.autoCdnTime;
    return time != 0 &&
        DateTime.now().millisecondsSinceEpoch - time < _ttl.inMilliseconds;
  }

  /// The ranking of the last test, fastest first; empty when outdated
  static List<CDNService> get ranking {
    if (!_isFresh) return const [];
    final names = Pref.autoCdnRanking;
    final res = <CDNService>[];
    for (final name in names) {
      for (final e in CDNService.values) {
        if (e.name == name) {
          res.add(e);
          break;
        }
      }
    }
    return res;
  }

  /// The CDN used at startup: the cached fastest one when the feature is on
  /// and the cache is fresh, the user's setting otherwise.
  static CDNService initialService() {
    try {
      if (_enabled) {
        final ranking = CdnAutoSelector.ranking;
        if (ranking.isNotEmpty) return ranking.first;
      }
    } catch (_) {}
    return Pref.defaultCDNService;
  }

  /// The user picked a CDN by hand: respect it until the cache expires.
  static void onManualSelect(CDNService service) {
    if (!_enabled) return;
    GStorage.setting
      ..put(SettingBoxKey.autoCdnRanking, [service.name])
      ..put(SettingBoxKey.autoCdnTime, DateTime.now().millisecondsSinceEpoch);
  }

  /// Called when the feature is switched.
  static void onToggle(bool enabled) {
    if (enabled) {
      VideoUtils.cdnService = initialService();
    } else {
      VideoUtils.cdnService = Pref.defaultCDNService;
    }
  }

  /// Starts a background speed test with [playUrls] (the play urls of the
  /// video being played) unless one ran recently. Never throws.
  static void maybeRun(Iterable<String> playUrls) {
    if (!_enabled || _running || _isFresh) return;
    final urls = playUrls.toList(growable: false);
    if (urls.isEmpty) return;
    _running = true;
    _run(urls).whenComplete(() => _running = false).ignore();
  }

  static Future<void> _run(List<String> urls) async {
    final client = HttpClient()
      ..connectionTimeout = _perHostTimeout
      ..idleTimeout = const Duration(seconds: 2)
      ..autoUncompress = false;
    try {
      // dedupe by resulting url: several services may resolve to the same url
      final tests = <String, CDNService>{};
      for (final service in candidates) {
        try {
          final url = VideoUtils.getCdnUrl(urls, defaultCDNService: service);
          tests.putIfAbsent(url, () => service);
        } catch (_) {}
      }

      final results = <CDNService, double>{};
      final entries = tests.entries.toList();
      int next = 0;
      Future<void> worker() async {
        while (next < entries.length) {
          final entry = entries[next++];
          final speed = await _measure(client, entry.key);
          if (speed != null) results[entry.value] = speed;
        }
      }

      await Future.wait(List.generate(_concurrency, (_) => worker()));

      if (results.isEmpty) {
        if (kDebugMode) debugPrint('CdnAutoSelector: every CDN failed');
        return;
      }

      final sorted = results.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (kDebugMode) {
        debugPrint(
          'CdnAutoSelector: ${sorted.map((e) => '${e.key.name}=${(e.value / 1024 / 1024).toStringAsFixed(2)}MB/s').join(', ')}',
        );
      }

      // the user may have turned it off while testing
      if (!_enabled) return;

      final ranking = sorted.map((e) => e.key.name).toList();
      await GStorage.setting.putAll({
        SettingBoxKey.autoCdnRanking: ranking,
        SettingBoxKey.autoCdnTime: DateTime.now().millisecondsSinceEpoch,
      });
      VideoUtils.cdnService = sorted.first.key;
    } catch (e) {
      if (kDebugMode) debugPrint('CdnAutoSelector: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Bytes per second, `null` on failure
  static Future<double?> _measure(HttpClient client, String url) async {
    final stopwatch = Stopwatch()..start();
    HttpClientRequest? request;
    try {
      request = await client.getUrl(Uri.parse(url)).timeout(_perHostTimeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, BrowserUa.pc)
        ..set(HttpHeaders.refererHeader, HttpString.baseUrl)
        ..set(HttpHeaders.rangeHeader, 'bytes=0-${_sampleBytes - 1}');
      final remaining = _perHostTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        request.abort();
        return null;
      }
      final response = await request.close().timeout(remaining);
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        unawaited(response.drain<void>().catchError((_) {}));
        return null;
      }

      int received = 0;
      final done = Completer<void>();
      late final StreamSubscription<List<int>> sub;
      final timer = Timer(_perHostTimeout - stopwatch.elapsed, () {
        if (!done.isCompleted) done.complete();
      });
      sub = response.listen(
        (chunk) {
          received += chunk.length;
          if (received >= _sampleBytes && !done.isCompleted) done.complete();
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
      timer.cancel();
      stopwatch.stop();
      await sub.cancel();
      // too little to tell anything apart from the round trip
      if (received < 16 * 1024) return null;
      return received / (stopwatch.elapsedMicroseconds / 1e6);
    } catch (_) {
      request?.abort();
      return null;
    }
  }
}
