import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 直播强制原画
///
/// Ported from the `enhance-live` module of
/// https://github.com/SukkaW/Make-Bilibili-Great-Than-Ever-Before :
/// a transcoded live stream is named `live_<uid>_<id>_<suffix>` (for example
/// `_bluray`, `_2500`, `_minihevc`), dropping the suffix gives the source
/// stream (原画). A Tencent `smtcdns.net` relay in front of a bilivideo host is
/// dropped as well.
abstract final class LiveOriginUtils {
  static final _qualityRegexp = RegExp(r'(live-bvc/\d+/live_\d+_\d+)_\w+');
  static final _hevcRegexp = RegExp(r'(\d+)_(?:mini|pro)hevc');
  static final _smtcdnsRegexp = RegExp(
    r'[\w.]+\.smtcdns\.net/([\w-]+\.bilivideo\.com/)',
  );

  static const _probeTimeout = Duration(seconds: 3);

  /// The url of the source stream, `null` when [url] is already one
  static String? forceOrigin(String url) {
    try {
      String res = url;
      if (_qualityRegexp.hasMatch(res)) {
        res = res
            .replaceFirstMapped(_qualityRegexp, (m) => m[1]!)
            .replaceAllMapped(_hevcRegexp, (m) => m[1]!);
      }
      if (_smtcdnsRegexp.hasMatch(res)) {
        res = res.replaceFirstMapped(_smtcdnsRegexp, (m) => m[1]!);
      }
      return res == url ? null : res;
    } catch (_) {
      return null;
    }
  }

  /// Whether the CDN serves [url]: only the response headers are awaited
  static Future<bool> probe(String url) async {
    final client = HttpClient()
      ..connectionTimeout = _probeTimeout
      ..autoUncompress = false;
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(_probeTimeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, BrowserUa.pc)
        ..set(HttpHeaders.refererHeader, HttpString.baseUrl);
      final response = await request.close().timeout(_probeTimeout);
      final status = response.statusCode;
      // a live stream never ends: do not read the body
      unawaited(
        response.listen(null).cancel().catchError((_) {}),
      );
      final ok = status >= 200 && status < 300;
      if (kDebugMode && !ok) {
        debugPrint('LiveOriginUtils: $status for $url');
      }
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('LiveOriginUtils: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
