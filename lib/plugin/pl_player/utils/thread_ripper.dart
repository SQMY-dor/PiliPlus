import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/cdn_auto_select.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 多 CDN 并发分片加速 (Thread Ripper, experimental)
///
/// Port of the `thread-ripper` module of
/// https://github.com/SukkaW/Make-Bilibili-Great-Than-Ever-Before for mpv:
/// a loopback HTTP server receives the player's (range) requests for a DASH
/// stream, splits the range into pieces, fetches the pieces in parallel from
/// several upos mirrors (the same signed path works on every upos host) and
/// streams them back to the player in order.
///
/// Robustness:
/// - only upos-signed `upgcxcode` urls are proxied, anything else is played
///   directly ([wrap] returns the url unchanged);
/// - every piece is checked (206, exact Content-Range, same file size) and
///   retried on other hosts, the player's own url included;
/// - when nothing was sent yet, a failure redirects the player (302) to the
///   original url; several failures in a short time turn the proxy off for a
///   while.
final class ThreadRipper {
  ThreadRipper._();

  static final ThreadRipper instance = ThreadRipper._();

  static const _kib = 1024;
  static const _mib = 1024 * _kib;

  /// Size of one piece
  static const _pieceSize = _mib;

  /// Pieces in flight (and buffered) per player request
  static const _window = 6;

  /// Hosts per stream, the original one included
  static const _maxHosts = 4;

  static const _connectTimeout = Duration(seconds: 4);

  /// No byte for this long: the attempt is given up
  static const _stallTimeout = Duration(seconds: 5);

  /// One attempt at one piece takes at most this long
  static const _attemptTimeout = Duration(seconds: 12);

  /// Streams remembered (the newest ones)
  static const _maxTargets = 16;

  static const _failuresToTurnOff = 3;
  static const _failureWindow = Duration(minutes: 1);
  static const _offDuration = Duration(minutes: 5);

  /// Used when no automatic CDN ranking is available
  static const _defaultServices = [
    CDNService.ali,
    CDNService.cos,
    CDNService.hw,
    CDNService.hw_08c,
  ];

  HttpServer? _server;
  Future<HttpServer?>? _starting;

  final HttpClient _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = _connectTimeout
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 6;

  final _targets = <String, _Target>{};
  int _seq = 0;

  final _failures = Queue<DateTime>();
  DateTime? _offUntil;

  bool get _isOff {
    final offUntil = _offUntil;
    return offUntil != null && DateTime.now().isBefore(offUntil);
  }

  /// [video] and [audio] wrapped by [wrap]
  Future<(String, String?)> wrapPair(String video, String? audio) async {
    final res = await Future.wait([
      wrap(video),
      if (audio != null && audio.isNotEmpty) wrap(audio),
    ]);
    return (res[0], res.length > 1 ? res[1] : audio);
  }

  /// A loopback url serving [url] through the proxy, or [url] itself when
  /// it cannot be proxied. Never throws.
  Future<String> wrap(String url) async {
    try {
      if (_isOff) return url;
      final uri = Uri.tryParse(url);
      if (uri == null || !_isEligible(uri)) return url;

      final hosts = _candidateUrls(uri);
      if (hosts.length < 2) return url;

      final server = await _ensureServer();
      if (server == null) return url;

      final id = (++_seq).toString();
      _targets[id] = _Target(url, hosts.map(_Host.new).toList());
      while (_targets.length > _maxTargets) {
        _targets.remove(_targets.keys.first);
      }
      final name = uri.pathSegments.isEmpty ? 'stream' : uri.pathSegments.last;
      return 'http://${InternetAddress.loopbackIPv4.address}:${server.port}/tr/$id/$name';
    } catch (e) {
      if (kDebugMode) debugPrint('ThreadRipper: wrap failed: $e');
      return url;
    }
  }

  static bool _isEligible(Uri uri) {
    if (uri.scheme != 'https' && uri.scheme != 'http') return false;
    if (!uri.path.contains('/upgcxcode/')) return false;
    final query = uri.queryParameters;
    // Akamai only accepts its own signature, it can never be swapped
    if (query.containsKey('hdnts') || uri.host.endsWith('.akamaized.net')) {
      return false;
    }
    return query.containsKey('upsig');
  }

  static List<String> _candidateUrls(Uri uri) {
    final res = <String>[uri.toString()];
    final seen = <String>{uri.host};
    final ranking = CdnAutoSelector.ranking;
    final services = ranking.isNotEmpty ? ranking : _defaultServices;
    for (final service in services) {
      if (res.length >= _maxHosts) break;
      final host = service.host;
      if (host == null || host.endsWith('.akamaized.net')) continue;
      if (!seen.add(host)) continue;
      res.add(uri.replace(host: host).toString());
    }
    if (ranking.isNotEmpty && res.length < _maxHosts) {
      for (final service in _defaultServices) {
        if (res.length >= _maxHosts) break;
        final host = service.host!;
        if (!seen.add(host)) continue;
        res.add(uri.replace(host: host).toString());
      }
    }
    return res;
  }

  Future<HttpServer?> _ensureServer() {
    if (_server case final server?) return Future.value(server);
    return _starting ??= () async {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
          shared: false,
        );
        server
          ..autoCompress = false
          ..idleTimeout = const Duration(seconds: 30)
          ..listen(
            (request) => _handle(request).catchError((Object e) {
              if (kDebugMode) debugPrint('ThreadRipper: $e');
            }),
            onError: (Object e) {
              if (kDebugMode) debugPrint('ThreadRipper: server error: $e');
            },
            onDone: () {
              _server = null;
              _starting = null;
            },
          );
        return _server = server;
      } catch (e) {
        if (kDebugMode) debugPrint('ThreadRipper: bind failed: $e');
        _starting = null;
        return null;
      }
    }();
  }

  void _recordFailure() {
    final now = DateTime.now();
    _failures.addLast(now);
    while (_failures.isNotEmpty &&
        now.difference(_failures.first) > _failureWindow) {
      _failures.removeFirst();
    }
    if (_failures.length >= _failuresToTurnOff) {
      _failures.clear();
      _offUntil = now.add(_offDuration);
      if (kDebugMode) debugPrint('ThreadRipper: too many failures, off');
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final target = segments.length >= 2 && segments[0] == 'tr'
        ? _targets[segments[1]]
        : null;

    if (target == null) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }

    final isHead = request.method == 'HEAD';
    if (!isHead && request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
      return response.close();
    }

    Future<void> redirect() {
      response
        ..statusCode = HttpStatus.found
        ..headers.contentLength = 0
        ..headers.set(HttpHeaders.locationHeader, target.original);
      return response.close();
    }

    if (_isOff) return redirect();

    final int total;
    try {
      total = await target.ensureSize(this);
    } catch (e) {
      if (kDebugMode) debugPrint('ThreadRipper: size probe failed: $e');
      _recordFailure();
      return redirect();
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final range = _parseRange(rangeHeader, total);
    if (rangeHeader != null && range == null) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total')
        ..headers.contentLength = 0;
      return response.close();
    }
    final start = range?.$1 ?? 0;
    final end = range?.$2 ?? total - 1;

    final headers = response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, target.contentType)
      ..contentLength = end - start + 1;
    if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    } else {
      response.statusCode = HttpStatus.ok;
    }

    if (isHead || end < start) {
      return response.close();
    }

    final job = _Job(target, total);
    bool clientGone = false;
    response.done.then<void>(
      (_) {},
      onError: (Object _) {
        clientGone = true;
        job.abortAll();
      },
    );

    final queue = Queue<Future<Uint8List>>();
    int next = start;
    bool first = true;
    void fill() {
      while (next <= end && queue.length < _window) {
        final pieceEnd = math.min(next + _pieceSize - 1, end);
        queue.add(_fetchPiece(job, next, pieceEnd, race: first));
        first = false;
        next = pieceEnd + 1;
      }
    }

    bool sentAny = false;
    try {
      fill();
      while (queue.isNotEmpty) {
        final bytes = await queue.removeFirst();
        if (clientGone) break;
        try {
          response.add(bytes);
          sentAny = true;
          await response.flush();
        } catch (_) {
          // the player closed the connection (seek, stop, ...)
          clientGone = true;
        }
        if (clientGone) break;
        fill();
      }
    } catch (e) {
      if (!clientGone) {
        if (kDebugMode) debugPrint('ThreadRipper: job failed: $e');
        _recordFailure();
        if (!sentAny) {
          // nothing went out yet: hand the player its own url
          job.abortAll();
          for (final f in queue) {
            f.ignore();
          }
          queue.clear();
          try {
            headers
              ..removeAll(HttpHeaders.contentRangeHeader)
              ..removeAll(HttpHeaders.acceptRangesHeader)
              ..removeAll(HttpHeaders.contentTypeHeader);
            return await redirect();
          } catch (_) {}
        }
      }
    } finally {
      job.abortAll();
      for (final f in queue) {
        f.ignore();
      }
    }

    try {
      await response.close();
    } catch (_) {
      // an incomplete body (fewer bytes than Content-Length): dart:io drops
      // the connection and the player sees a truncated read
    }
  }

  /// `(start, end)` inclusive, `null` when absent or not satisfiable
  static (int, int)? _parseRange(String? header, int total) {
    if (header == null) return null;
    final value = header.trim();
    if (!value.startsWith('bytes=')) return null;
    // multiple ranges: only the first is served
    final spec = value.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash == -1) return null;
    final a = spec.substring(0, dash).trim();
    final b = spec.substring(dash + 1).trim();
    if (a.isEmpty) {
      // suffix range: the last n bytes
      final n = int.tryParse(b);
      if (n == null || n <= 0) return null;
      return (math.max(0, total - n), total - 1);
    }
    final start = int.tryParse(a);
    if (start == null || start < 0 || start >= total) return null;
    int end = b.isEmpty ? total - 1 : (int.tryParse(b) ?? -1);
    if (end < start) return null;
    end = math.min(end, total - 1);
    return (start, end);
  }

  Future<Uint8List> _fetchPiece(
    _Job job,
    int start,
    int end, {
    bool race = false,
  }) async {
    final target = job.target;
    final tried = <_Host>{};
    Object? lastError;
    while (!job.aborted) {
      final hosts = target.pick(race && tried.isEmpty ? 2 : 1, tried);
      if (hosts.isEmpty) break;
      tried.addAll(hosts);
      try {
        return hosts.length == 1
            ? await _fetchFrom(job, hosts.first, start, end)
            : await _race(job, hosts, start, end);
      } catch (e) {
        lastError = e;
      }
    }
    // last resort: the player's own url, even if it failed before
    if (!job.aborted) {
      try {
        return await _fetchFrom(job, target.hosts.first, start, end);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const HttpException('aborted');
  }

  Future<Uint8List> _race(_Job job, List<_Host> hosts, int start, int end) {
    final completer = Completer<Uint8List>();
    final aborts = <_Abort>[];
    int pending = hosts.length;
    for (final host in hosts) {
      final abort = _Abort();
      aborts.add(abort);
      _fetchFrom(job, host, start, end, abort).then(
        (bytes) {
          if (completer.isCompleted) return;
          completer.complete(bytes);
          for (final other in aborts) {
            if (!identical(other, abort)) other.abort();
          }
        },
        onError: (Object e) {
          if (--pending == 0 && !completer.isCompleted) {
            completer.completeError(e);
          }
        },
      );
    }
    return completer.future;
  }

  Future<Uint8List> _fetchFrom(
    _Job job,
    _Host host,
    int start,
    int end, [
    _Abort? abort,
  ]) async {
    abort ??= _Abort();
    job.aborts.add(abort);
    host.inflight++;
    final stopwatch = Stopwatch()..start();
    final deadline = Timer(_attemptTimeout, () {
      abort!
        ..timedOut = true
        ..abort();
    });
    try {
      final request = await _client
          .getUrl(Uri.parse(host.url))
          .timeout(_connectTimeout);
      abort.request = request;
      if (abort.aborted) {
        request.abort();
        throw const HttpException('aborted');
      }
      _setHeaders(request.headers, 'bytes=$start-$end');
      final response = await request.close().timeout(_attemptTimeout);
      if (response.statusCode != HttpStatus.partialContent) {
        unawaited(response.drain<void>().catchError((_) {}));
        throw HttpException('status ${response.statusCode}');
      }
      final contentRange = _parseContentRange(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (contentRange == null ||
          contentRange.$1 != start ||
          contentRange.$2 != end ||
          contentRange.$3 != job.total) {
        unawaited(response.drain<void>().catchError((_) {}));
        throw const HttpException('unexpected Content-Range');
      }

      final expected = end - start + 1;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_stallTimeout)) {
        builder.add(chunk);
        if (builder.length > expected) {
          throw const HttpException('too many bytes');
        }
      }
      if (builder.length != expected) {
        throw const HttpException('truncated');
      }
      stopwatch.stop();
      host.onSuccess(expected, stopwatch.elapsedMicroseconds);
      return builder.takeBytes();
    } catch (e) {
      if (!abort.aborted || abort.timedOut) host.onFailure();
      abort.request?.abort();
      rethrow;
    } finally {
      deadline.cancel();
      host.inflight--;
      job.aborts.remove(abort);
    }
  }

  static void _setHeaders(HttpHeaders headers, String range) {
    headers
      ..set(HttpHeaders.userAgentHeader, BrowserUa.pc)
      ..set(HttpHeaders.refererHeader, HttpString.baseUrl)
      ..set(HttpHeaders.acceptEncodingHeader, 'identity')
      ..set(HttpHeaders.rangeHeader, range);
  }

  /// `(start, end, total)` of `bytes start-end/total`
  static (int, int, int?)? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    if (match == null) return null;
    return (
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.tryParse(match[3]!),
    );
  }

  Future<(int, String?)> _probeSize(_Host host) async {
    final request = await _client
        .getUrl(Uri.parse(host.url))
        .timeout(_connectTimeout);
    _setHeaders(request.headers, 'bytes=0-0');
    final response = await request.close().timeout(_attemptTimeout);
    unawaited(response.drain<void>().catchError((_) {}));
    if (response.statusCode != HttpStatus.partialContent) {
      throw HttpException('status ${response.statusCode}');
    }
    final total = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    )?.$3;
    if (total == null || total <= 0) {
      throw const HttpException('unknown size');
    }
    return (total, response.headers.value(HttpHeaders.contentTypeHeader));
  }
}

final class _Target {
  _Target(this.original, this.hosts);

  final String original;

  /// The player's own url first
  final List<_Host> hosts;

  int? _total;
  String contentType = 'video/mp4';
  Future<int>? _sizing;

  Future<int> ensureSize(ThreadRipper ripper) {
    if (_total case final total?) return Future.value(total);
    return _sizing ??= () async {
      Object? lastError;
      // the player's own url first, then the others
      for (final host in hosts) {
        try {
          final (total, type) = await ripper._probeSize(host);
          if (type != null && type.isNotEmpty) contentType = type;
          return _total = total;
        } catch (e) {
          host.onFailure();
          lastError = e;
        }
      }
      _sizing = null;
      throw lastError ?? const HttpException('no host');
    }();
  }

  /// Up to [count] usable hosts not in [exclude], the expected fastest first
  List<_Host> pick(int count, Set<_Host> exclude) {
    final usable = hosts
        .where((h) => !h.banned && !exclude.contains(h))
        .toList();
    if (usable.isEmpty) return const [];
    final known = hosts.where((h) => h.speed > 0).map((h) => h.speed);
    // an unmeasured host is assumed as fast as the average measured one,
    // so that it gets explored
    final fallback = known.isEmpty
        ? 1.0
        : known.reduce((a, b) => a + b) / known.length;
    double eta(_Host h) =>
        (h.inflight + 1) / (h.speed > 0 ? h.speed : fallback);
    usable.sort((a, b) => eta(a).compareTo(eta(b)));
    return usable.take(count).toList();
  }
}

final class _Host {
  _Host(this.url);

  final String url;
  int inflight = 0;
  int _consecutiveFailures = 0;

  /// Bytes per microsecond, moving average; 0 when unmeasured
  double speed = 0;

  bool get banned => _consecutiveFailures >= 2;

  void onSuccess(int bytes, int micros) {
    _consecutiveFailures = 0;
    if (micros <= 0) return;
    final sample = bytes / micros;
    speed = speed == 0 ? sample : speed * 0.7 + sample * 0.3;
  }

  void onFailure() => _consecutiveFailures++;
}

final class _Job {
  _Job(this.target, this.total);

  final _Target target;
  final int total;
  final Set<_Abort> aborts = {};
  bool aborted = false;

  void abortAll() {
    aborted = true;
    for (final abort in aborts.toList()) {
      abort.abort();
    }
  }
}

final class _Abort {
  HttpClientRequest? request;
  bool aborted = false;

  /// aborted by the per-attempt deadline rather than by a winner / the job
  bool timedOut = false;

  void abort() {
    if (aborted) return;
    aborted = true;
    request?.abort();
  }
}
