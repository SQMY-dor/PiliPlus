// 大肥鱼消除计划：识别 B 站评论区里由 DeepSeek 等大模型驱动的机器人账号
// ported from https://github.com/liyupi/dafeiyu-cleaner (MIT)
//
// 只在本地标记 / 折叠 / 隐藏，不删评论、不举报、不调用任何 B 站写接口。

import 'dart:async';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/utils/dafeiyu/dafeiyu_llm.dart';
import 'package:PiliPlus/utils/dafeiyu/detector.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

export 'package:PiliPlus/utils/dafeiyu/detector.dart'
    show DfyLevel, DfyVerdict, DfyReason;

enum DfyAction with EnumWithLabel {
  mark('仅标记'),
  fold('折叠'),
  hide('直接隐藏');

  const DfyAction(this.label);
  @override
  final String label;
}

class _Acc {
  _Acc(this.verdict, this.name, this.level, this.texts);
  DfyVerdict verdict;
  String name;
  int level;
  List<String> texts;
}

abstract final class Dafeiyu {
  static bool enable = Pref.dfyEnable;
  static int threshold = Pref.dfyThreshold;
  static DfyAction action = Pref.dfyAction;

  // DeepSeek 精判
  static bool llmEnable = Pref.dfyLlmEnable;
  static bool llmAuto = Pref.dfyLlmAuto;
  static String llmKey = Pref.dfyLlmKey;
  static String llmModel = Pref.dfyLlmModel;
  static bool get canLlm => llmEnable && llmKey.isNotEmpty;

  static const _llmTtl = 7 * 24 * 3600 * 1000;
  static const _llmMax = 3000;

  /// mid -> DeepSeek result, cached for 7 days
  static final Map<int, DfyLlmResult> _llmCache = Pref.dfyLlmCache;
  static final Set<int> _llmDone = {};
  static bool _llmBusy = false;

  /// bumped whenever verdicts change outside of a list load (DeepSeek results,
  /// whitelist edits), so visible comments can rebuild
  static final ValueNotifier<int> tick = ValueNotifier(0);

  /// 「是人类」：以后不再标记
  static final Set<int> whitelist = Pref.dfyWhitelist;

  /// 遣返名单：手动赶走过的账号，以后一律按大肥鱼处理
  static final Set<int> sentHome = Pref.dfySentHome;

  /// 前科：mid -> 被认出过的页面 (oid)，最多记 6 个
  static final Map<int, List<int>> _priors = Pref.dfyPriors;

  /// mid -> offline verdict and evidence of the latest page it appeared on
  static final Map<int, _Acc> _accounts = {};

  /// rpids folded by the user and then expanded again
  static final Set<int> expanded = {};

  static DfyLlmResult? llmOf(int mid) {
    final r = _llmCache[mid];
    if (r == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - r.time > _llmTtl) {
      _llmCache.remove(mid);
      return null;
    }
    return r;
  }

  static DfyVerdict? verdictOf(ReplyInfo item) {
    if (!enable) return null;
    final mid = item.mid.toInt();
    if (whitelist.contains(mid)) return null;
    final acc = _accounts[mid];
    DfyVerdict? v = acc?.verdict;
    if (v != null && llmEnable) {
      if (llmOf(mid) case final llm?) {
        final score = (v.score * 0.45 + llm.ai * 0.55).round();
        v = DfyVerdict(
          score: score,
          raw: v.raw,
          level: DfyDetector.levelOf(score, threshold),
          reasons: v.reasons,
          offline: v.score,
          llmAi: llm.ai,
          llmReason: llm.reason,
        );
      }
    }
    if (sentHome.contains(mid)) {
      return DfyVerdict(
        score: 99,
        raw: v?.raw ?? 99,
        level: DfyLevel.fish,
        reasons: [
          const DfyReason(99, '已在遣返名单里（你亲手赶走过）', 'history'),
          ...?v?.reasons,
        ],
        offline: v?.offline ?? v?.score,
        llmAi: v?.llmAi,
        llmReason: v?.llmReason,
      );
    }
    return v;
  }

  static bool isFish(ReplyInfo item) =>
      verdictOf(item)?.level == DfyLevel.fish;

  /// whether the comment should be folded in the list right now
  static bool shouldFold(ReplyInfo item) =>
      action == DfyAction.fold &&
      !expanded.contains(item.id.toInt()) &&
      isFish(item);

  /// whether the comment should be hidden in the list right now (used for
  /// comments that turned into fish after the list was loaded)
  static bool shouldHide(ReplyInfo item) =>
      action == DfyAction.hide && isFish(item);

  /// Judge a page of comments. [roots] are top-level comments (their
  /// `replies` are scanned too) or the flat replies of a detail page.
  /// In [DfyAction.hide] mode the fish are removed from [roots] in place.
  static void process(
    List<ReplyInfo> roots, {
    Int64? upMid,
    ReplyInfo? root,
  }) {
    if (!enable || roots.isEmpty && root == null) return;
    try {
      final mids = _judge(roots, upMid: upMid?.toInt(), root: root);
      if (action == DfyAction.hide) {
        roots.removeWhere((item) {
          if (isFish(item)) return true;
          if (item.replies.isNotEmpty) item.replies.removeWhere(isFish);
          return false;
        });
      }
      if (canLlm && llmAuto) _autoLlm(mids);
    } catch (_) {}
  }

  static Set<int> _judge(
    List<ReplyInfo> roots, {
    int? upMid,
    ReplyInfo? root,
  }) {
    final all = <ReplyInfo>[?root];
    for (final item in roots) {
      all.add(item);
      if (item.replies.isNotEmpty) all.addAll(item.replies);
    }
    if (_accounts.length > 4000) _accounts.clear();

    final byMid = <int, List<ReplyInfo>>{};
    final topCount = <int, int>{};
    for (final item in all) {
      final mid = item.mid.toInt();
      (byMid[mid] ??= []).add(item);
      if (item.root == Int64.ZERO) {
        topCount[mid] = (topCount[mid] ?? 0) + 1;
      }
    }

    final called = DfyDetector.callouts(
      all.map(
        (e) => (
          mid: e.mid.toInt(),
          uname: e.member.name,
          rpid: e.id.toInt(),
          root: e.root.toInt(),
          text: e.content.message,
          isReply: e.root != Int64.ZERO,
        ),
      ),
    );

    bool priorsChanged = false;
    for (final MapEntry(key: mid, value: items) in byMid.entries) {
      final first = items.first;
      final member = first.member;
      final oid = first.oid.toInt();
      final prior = _priors[mid]?.where((e) => e != oid).length ?? 0;
      final texts = items.map((e) => e.content.message).toList();
      final verdict = DfyDetector.judge(
        DfyAccount(
          mid: mid,
          uname: member.name,
          level: member.level.toInt(),
          verify: member.officialVerifyType.toInt(),
          vip: member.vipStatus.toInt(),
        ),
        items
            .map(
              (e) => DfyText(
                e.content.message,
                isReply: e.root != Int64.ZERO,
              ),
            )
            .toList(),
        threshold: threshold,
        topCount: topCount[mid] ?? 0,
        upMid: upMid,
        calledOut: called[mid] ?? 0,
        priorPages: prior,
      );
      _accounts[mid] = _Acc(
        verdict,
        member.name,
        member.level.toInt(),
        texts,
      );
      // 只凭本页证据就够得上大肥鱼时才记前科；DeepSeek 判为人类时不记
      final llm = llmEnable ? llmOf(mid) : null;
      if (verdict.raw >= threshold && oid != 0 && (llm == null || llm.ai >= 50)) {
        final list = _priors[mid] ??= <int>[];
        if (!list.contains(oid)) {
          list.add(oid);
          if (list.length > 6) list.removeAt(0);
          priorsChanged = true;
        }
      }
    }
    if (priorsChanged) {
      if (_priors.length > 3000) {
        _priors.remove(_priors.keys.first);
      }
      GStorage.localCache.put(LocalCacheKey.dfyPriors, _priors);
    }
    return byMid.keys.toSet();
  }

  /// 离线分 20–85 的不确定账号，每批最多 8 个
  static bool _needsLlm(int mid) {
    if (whitelist.contains(mid) || sentHome.contains(mid)) return false;
    if (_llmDone.contains(mid) || llmOf(mid) != null) return false;
    final score = _accounts[mid]?.verdict.score;
    return score != null && score >= 20 && score < 85;
  }

  static final List<int> _queue = [];

  static void _autoLlm(Set<int> mids) {
    for (final mid in mids) {
      if (_needsLlm(mid) && !_queue.contains(mid)) _queue.add(mid);
    }
    if (_queue.length > 40) _queue.removeRange(0, _queue.length - 40);
    _drain();
  }

  static Future<void> _drain() async {
    if (_llmBusy || _queue.isEmpty || !canLlm) return;
    final batch = <int>[];
    while (_queue.isNotEmpty && batch.length < 8) {
      final mid = _queue.removeAt(0);
      if (_needsLlm(mid)) batch.add(mid);
    }
    if (batch.isEmpty) return;
    final res = await _judgeLlm(batch);
    if (res != null && res.ok) unawaited(_drain());
  }

  /// manual 精判 of one account from the report dialog
  static Future<DfyVerdict?> judgeNow(ReplyInfo item) async {
    if (!canLlm) {
      SmartDialog.showToast('先在设置里开启 DeepSeek 精判并填入密钥');
      return null;
    }
    final mid = item.mid.toInt();
    if (_accounts[mid] == null) return null;
    _llmDone.remove(mid);
    SmartDialog.showLoading(msg: 'DeepSeek 正在深度思考…');
    final res = await _judgeLlm([mid]);
    SmartDialog.dismiss();
    if (res == null) return null;
    if (!res.ok) {
      SmartDialog.showToast(res.error ?? '精判失败');
      return null;
    }
    SmartDialog.showToast('已深度思考（用时 ${(res.ms / 1000).toStringAsFixed(1)} 秒）');
    return verdictOf(item);
  }

  static Future<DfyLlmResponse?> _judgeLlm(List<int> mids) async {
    final items = <DfyLlmItem>[];
    for (final mid in mids) {
      final acc = _accounts[mid];
      if (acc == null) continue;
      items.add(
        DfyLlmItem(
          mid: mid,
          name: acc.name,
          level: acc.level,
          offline: acc.verdict.score,
          hints: acc.verdict.reasons.take(4).map((r) => r.why).toList(),
          comments: acc.texts
              .take(3)
              .map((t) => t.length > 220 ? t.substring(0, 220) : t)
              .toList(),
        ),
      );
    }
    if (items.isEmpty) return null;
    _llmBusy = true;
    _llmDone.addAll(mids);
    try {
      final res = await DfyLlm.judgeComments(
        items,
        key: llmKey,
        model: llmModel,
      );
      if (res.ok && res.results.isNotEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        res.results.forEach((mid, r) {
          _llmCache[mid] = DfyLlmResult(r.ai, r.reason, now);
        });
        _saveLlm();
        tick.value++;
      }
      return res;
    } finally {
      _llmBusy = false;
    }
  }

  static void _saveLlm() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _llmCache.removeWhere((_, v) => now - v.time > _llmTtl);
    while (_llmCache.length > _llmMax) {
      _llmCache.remove(_llmCache.keys.first);
    }
    GStorage.localCache.put(
      LocalCacheKey.dfyLlmCache,
      _llmCache.map((k, v) => MapEntry(k, v.toJson())),
    );
  }

  static void clearLlmCache() {
    _llmCache.clear();
    _llmDone.clear();
    _saveLlm();
    tick.value++;
  }

  static int get llmCacheSize => _llmCache.length;

  static void markHuman(int mid) {
    sentHome.remove(mid);
    whitelist.add(mid);
    _priors.remove(mid);
    _save();
  }

  static void sendHome(int mid) {
    whitelist.remove(mid);
    sentHome.add(mid);
    _save();
  }

  static void clearLists() {
    whitelist.clear();
    sentHome.clear();
    _priors.clear();
    _save();
  }

  static void _save() {
    GStorage.localCache
      ..put(LocalCacheKey.dfyWhitelist, whitelist)
      ..put(LocalCacheKey.dfySentHome, sentHome)
      ..put(LocalCacheKey.dfyPriors, _priors);
    tick.value++;
  }
}
