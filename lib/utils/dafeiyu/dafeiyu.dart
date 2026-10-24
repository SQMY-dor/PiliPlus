// 大肥鱼消除计划：识别 B 站评论区里由 DeepSeek 等大模型驱动的机器人账号
// ported from https://github.com/liyupi/dafeiyu-cleaner (MIT)
//
// 只在本地标记 / 折叠 / 隐藏，不删评论、不举报、不调用任何写接口。

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/utils/dafeiyu/detector.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';

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

abstract final class Dafeiyu {
  static bool enable = Pref.dfyEnable;
  static int threshold = Pref.dfyThreshold;
  static DfyAction action = Pref.dfyAction;

  /// 「是人类」：以后不再标记
  static final Set<int> whitelist = Pref.dfyWhitelist;

  /// 遣返名单：手动赶走过的账号，以后一律按大肥鱼处理
  static final Set<int> sentHome = Pref.dfySentHome;

  /// 前科：mid -> 被认出过的页面 (oid)，最多记 6 个
  static final Map<int, List<int>> _priors = Pref.dfyPriors;

  /// rpid -> verdict
  static final Map<int, DfyVerdict> _verdicts = {};

  /// rpids folded by the user and then expanded again
  static final Set<int> expanded = {};

  static DfyVerdict? verdictOf(ReplyInfo item) {
    if (!enable) return null;
    final mid = item.mid.toInt();
    if (whitelist.contains(mid)) return null;
    if (sentHome.contains(mid)) {
      final v = _verdicts[item.id.toInt()];
      return DfyVerdict(
        score: 99,
        raw: v?.raw ?? 99,
        level: DfyLevel.fish,
        reasons: [
          const DfyReason(99, '已在遣返名单里（你亲手赶走过）', 'history'),
          ...?v?.reasons,
        ],
      );
    }
    return _verdicts[item.id.toInt()];
  }

  static bool isFish(ReplyInfo item) =>
      verdictOf(item)?.level == DfyLevel.fish;

  /// whether the comment should be folded in the list right now
  static bool shouldFold(ReplyInfo item) =>
      action == DfyAction.fold &&
      !expanded.contains(item.id.toInt()) &&
      isFish(item);

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
      _judge(roots, upMid: upMid?.toInt(), root: root);
      if (action == DfyAction.hide) {
        roots.removeWhere((item) {
          if (isFish(item)) return true;
          if (item.replies.isNotEmpty) item.replies.removeWhere(isFish);
          return false;
        });
      }
    } catch (_) {}
  }

  static void _judge(List<ReplyInfo> roots, {int? upMid, ReplyInfo? root}) {
    final all = <ReplyInfo>[?root];
    for (final item in roots) {
      all.add(item);
      if (item.replies.isNotEmpty) all.addAll(item.replies);
    }
    if (_verdicts.length > 4000) _verdicts.clear();

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
      for (final e in items) {
        _verdicts[e.id.toInt()] = verdict;
      }
      if (verdict.raw >= threshold && oid != 0) {
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
  }

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

  static void removeFromLists(int mid) {
    whitelist.remove(mid);
    sentHome.remove(mid);
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
  }
}
