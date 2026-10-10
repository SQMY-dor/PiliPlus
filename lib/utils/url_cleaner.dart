import 'package:PiliPlus/utils/storage_pref.dart';

/// 分享链接去除追踪参数
///
/// Parameter list from the `remove-useless-url-params` module of
/// https://github.com/SukkaW/Make-Bilibili-Great-Than-Ever-Before , plus the
/// ones Bilibili's apps add to shared links.
abstract final class UrlCleaner {
  static const _trackingParams = <String>{
    // from the userscript
    'buvid',
    'is_story_h5',
    'launch_id',
    'live_from',
    'mid',
    'session_id',
    'timestamp',
    'up_id',
    'vd_source',
    'trackid',
    // added by the apps when sharing
    'bbid',
    'ts',
    'unique_k',
    'from_source',
    'from_spmid',
    '-Arouter',
    'plat_id',
    'msource',
    'bsource',
    'seid',
  };

  /// `share_*` (share_source, share_medium, share_plat, share_session_id,
  /// share_tag, share_from, ...) and `spm*` (spm_id_from, spmid, ...)
  static final _trackingPrefix = RegExp(r'^(?:share|spm)');

  static final _bilibiliHost = RegExp(
    r'(?:^|\.)(?:bilibili\.com|b23\.tv|bili2233\.cn|bilibili\.tv)$',
  );

  static final _urlInText = RegExp(r'''https?://[^\s<>"'，。！？、）】」]+''');

  static bool get enabled => Pref.stripTrackingParams;

  static bool isTrackingParam(String key) =>
      _trackingParams.contains(key) || _trackingPrefix.hasMatch(key);

  /// Removes tracking parameters from a Bilibili [url], keeping the others
  /// exactly as they were encoded. Urls of other sites are returned as is.
  ///
  /// [keep] lists parameters that must stay (e.g. the ones a router reads).
  static String cleanUrl(String url, {Set<String> keep = const {}}) {
    try {
      final queryStart = url.indexOf('?');
      if (queryStart == -1) return url;

      final uri = Uri.tryParse(url);
      if (uri == null || !_bilibiliHost.hasMatch(uri.host)) return url;

      final hashStart = url.indexOf('#', queryStart);
      final query = hashStart == -1
          ? url.substring(queryStart + 1)
          : url.substring(queryStart + 1, hashStart);
      final fragment = hashStart == -1 ? '' : url.substring(hashStart);

      bool changed = false;
      final kept = <String>[];
      for (final part in query.split('&')) {
        if (part.isEmpty) {
          changed = true;
          continue;
        }
        final eq = part.indexOf('=');
        final rawKey = eq == -1 ? part : part.substring(0, eq);
        String key;
        try {
          key = Uri.decodeQueryComponent(rawKey);
        } catch (_) {
          key = rawKey;
        }
        if (!keep.contains(key) && isTrackingParam(key)) {
          changed = true;
        } else {
          kept.add(part);
        }
      }
      if (!changed) return url;

      final base = url.substring(0, queryStart);
      return kept.isEmpty
          ? '$base$fragment'
          : '$base?${kept.join('&')}$fragment';
    } catch (_) {
      return url;
    }
  }

  /// [cleanUrl] applied to every Bilibili link inside [text]
  static String cleanText(String text) {
    if (!text.contains('http')) return text;
    try {
      return text.replaceAllMapped(_urlInText, (m) => cleanUrl(m[0]!));
    } catch (_) {
      return text;
    }
  }

  /// [cleanText] when the feature is on
  static String maybeCleanText(String text) => enabled ? cleanText(text) : text;
}
