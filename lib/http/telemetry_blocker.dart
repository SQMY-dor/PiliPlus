import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

/// 屏蔽日志上报/埋点
///
/// Port of the `defuse-spyware` module of
/// https://github.com/SukkaW/Make-Bilibili-Great-Than-Ever-Before :
/// requests to Bilibili's log collection and ad-tracking endpoints are
/// answered locally with an empty success response and never leave the
/// device.
///
/// Watch history / heartbeat (`/x/click-interface/web/heartbeat`,
/// `/x/v2/history/report`, `roomEntryAction`) are NOT blocked: they stay
/// governed by the existing history settings. The buvid activation
/// (`/x/internal/gaia-gateway/ExClimbWuzhi`), blocked by the userscript, is
/// kept as well: the app relies on it to avoid risk control (-352/412).
class TelemetryBlocker extends Interceptor {
  const TelemetryBlocker();

  /// Hosts that only collect logs or track ads
  static final _blockedHostRegExp = RegExp(
    r'(?:^|\.)(?:data\.bilibili\.com|cm\.bilibili\.com|data\.bilivideo\.com|log\.bilibili\.com|cm\.hdslb\.com)$',
  );

  /// Log / exposure / click reporting paths on otherwise useful hosts
  static const _blockedPaths = <String>[
    '/log/web',
    '/x/web-frontend/data/collector',
    '/x/report/web/',
    '/x/report/click/',
    '/x/click-interface/click/',
    '/x/v2/view/report',
    '/x/internal/apm/',
    '/xlive/web-interface/v1/report/',
  ];

  /// Patterns for webview content blockers (regex on the full url)
  static const webviewUrlFilters = <String>[
    r'^https?://([a-z0-9-]+\.)*data\.bilibili\.com/.*',
    r'^https?://([a-z0-9-]+\.)*cm\.bilibili\.com/.*',
    r'^https?://([a-z0-9-]+\.)*data\.bilivideo\.com/.*',
    r'^https?://([a-z0-9-]+\.)*log\.bilibili\.com/.*',
    r'^https?://([a-z0-9-]+\.)*cm\.hdslb\.com/.*',
    r'.*/x/web-frontend/data/collector.*',
    r'.*/log/web\?.*',
  ];

  static bool get enabled => Pref.blockTelemetry;

  static bool shouldBlock(Uri uri) {
    if (_blockedHostRegExp.hasMatch(uri.host)) return true;
    final path = uri.path;
    for (final p in _blockedPaths) {
      if (path.startsWith(p)) return true;
    }
    return false;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      if (enabled && shouldBlock(options.uri)) {
        if (kDebugMode) debugPrint('TelemetryBlocker: ${options.uri}');
        return handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: options.responseType == ResponseType.json
                ? <String, dynamic>{'code': 0, 'message': '0', 'data': null}
                : options.responseType == ResponseType.plain
                ? ''
                : null,
          ),
        );
      }
    } catch (_) {}
    handler.next(options);
  }
}
