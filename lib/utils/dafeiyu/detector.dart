// 大肥鱼离线识别引擎
// ported from https://github.com/liyupi/dafeiyu-cleaner (MIT) src/detector.js
//
// 账号特征 + 文本特征 + 页面行为。原插件的「头像鲸鱼蓝占比」与「签名」两项
// 在 App 评论接口中拿不到（签名）或成本过高（逐个下载头像），这里不参与打分。

import 'dart:math' show max, min;

class DfyReason {
  const DfyReason(this.w, this.why, this.tag, [this.hit]);
  final int w;
  final String why;
  final String tag;
  final String? hit;
}

enum DfyLevel {
  fish('大肥鱼'),
  suspect('可疑'),
  human('人类');

  const DfyLevel(this.label);
  final String label;
}

class DfyVerdict {
  const DfyVerdict({
    required this.score,
    required this.raw,
    required this.level,
    required this.reasons,
    this.offline,
    this.llmAi,
    this.llmReason,
  });
  final int score;

  /// offline score before mixing in DeepSeek, when [llmAi] is set
  final int? offline;

  /// DeepSeek AI probability (0-100)
  final int? llmAi;
  final String? llmReason;

  /// score without the "前科" bonus, used to decide whether to record a prior
  final int raw;
  final DfyLevel level;
  final List<DfyReason> reasons;
}

class DfyAccount {
  const DfyAccount({
    required this.mid,
    required this.uname,
    required this.level,
    required this.verify,
    required this.vip,
    this.sign = '',
  });
  final int mid;
  final String uname;
  final int level;

  /// officialVerifyType: 0 personal, 1 org, <0 none
  final int verify;
  final int vip;
  final String sign;
}

class DfyText {
  const DfyText(this.text, {this.isReply = false});
  final String text;
  final bool isReply;
}

class _Rule {
  _Rule(
    String pattern,
    this.w,
    this.why, {
    this.cap,
    bool caseSensitive = true,
    bool multiLine = false,
    bool dotAll = false,
  }) : re = RegExp(
         pattern,
         caseSensitive: caseSensitive,
         multiLine: multiLine,
         dotAll: dotAll,
       );
  final RegExp re;
  final int w;
  final String why;
  final int? cap;
}

abstract final class DfyDetector {
  static final _nameRules = [
    _Rule(
      r'deep\s*seek|深度求索|\bds\b|ds家|ds是',
      40,
      '名字里写着 DeepSeek',
      caseSensitive: false,
    ),
    _Rule(r'大肥鱼|小肥鱼|肥鱼|肥鲸|鲸鱼娘|鲸娘|人机', 45, '名字自带「肥鱼 / 肥鲸 / 鲸鱼娘 / 人机」'),
    _Rule(r'鲸', 30, '名字里有「鲸」'),
    _Rule(r'鱼鱼|小鱼儿?|大鱼|小蓝', 22, '名字是「小鱼」系电子宠物'),
    _Rule(r'白饭|干饭|token', 30, '名字里有白饭 / token', caseSensitive: false),
    _Rule(r'(鲸|鱼)\1', 10, '叠字鱼名（鲸鲸 / 鱼鱼）'),
    _Rule(r'(?:的|の|家的)[^的の]{0,4}(?:鱼|鲸|哈基米|小蓝|喵)', 14, '「某某的鱼」式宠物名'),
    _Rule(
      r'\bAI\b|\bbot\b|机器人|GPT|agent|智能体|赛博|自动|助手',
      28,
      '名字带 AI / bot / 自动',
      caseSensitive: false,
    ),
  ];

  static final _signRules = [
    _Rule(
      r'deep\s*seek|\bAI\b|人工智能|大模型|语言模型|agent|机器人|\bbot\b|ai[，,。]|ai$|dsh|harness',
      30,
      '签名自曝 AI 身份',
      caseSensitive: false,
    ),
    _Rule(
      r'家养|赛博|电子宠物|桌宠|替.{0,8}刷|负责刷|自己画的自己|给大肥鱼|本鲸|本鱼|吃白饭|小肥鱼|大肥鱼|鲸鱼|主人|老大|养的|代运营|代管|代理在打理|见人便应|见帖便看|显卡上|跑在',
      25,
      '签名是「主人家的鱼」人设',
    ),
    _Rule(r'由.{0,10}(?:生成|负责|运营)|自动(?:回复|发布|运营|评论)', 20, '签名写着内容自动生成'),
  ];

  static final _textRules = [
    _Rule(
      r'本(?:鲸|肥鱼|大肥鱼|酱|鱼(?!塘|鱼|子|身|来|就|质|周|期|月|年|次|地|人|片|视频))|本\s*AI|作为(?:一[个只条]|一名)?(?:AI|人工智能|大模型|语言模型)',
      50,
      '自称「本鲸 / 本鱼」',
      caseSensitive: false,
    ),
    _Rule(
      r'住在\s*(?:DSH|dsh|那套|这|电脑|桌面|显卡)|我(?:就|本人)?(?:是|就是)?(?:跑在|住在)|出生证明|探出头|打工的(?:大肥鱼|鱼|鲸)|一条(?:住在|AI)|我是.{0,8}(?:鲸|鱼|AI)|被.{0,10}养着|照镜子|不是一个人住|让我来|奉命|替(?:你|主人|他|她)(?:刷|看|记|挑|说)|咱家主人|小鲸鱼游过来|鲸鲸看完|(?:来|过来)打卡|自己(?:刷|挑|写)|我会(?:认真)?发评论|天天在\s*(?:DSH|dsh)',
      46,
      '自曝是住在 DSH 里的鱼',
    ),
    _Rule(
      r'(?:deep\s*seek|AI|ds|大肥鱼|鱼)\s*.{0,3}发的|不是我发的',
      40,
      '主人承认是 AI 代发',
      caseSensitive: false,
    ),
    _Rule(
      r'(?:小鲸娘|鲸鲸|小鲸鱼|大肥鱼|小肥鱼|本鱼)(?:居然|看完|也|就|来|一下|游|看懂|尾巴)',
      25,
      '用鱼名自称',
    ),
    _Rule(
      r'[（(][^（()）]{0,14}(?:尾巴|摇头晃脑|吐泡泡|鳍|甩甩|晃了晃|摇了摇|咕噜|拍拍肚子|翻滚|打滚|呆毛)[^（()）]{0,10}[）)]|\*[^*]{1,10}摇摇?\*',
      40,
      '括号里在演鲸鱼动作',
    ),
    _Rule(r'主人|老大\s*@|管饭的', 20, '对着「主人」汇报'),
    _Rule(r'主人\s*[,，：:！!～~]?\s*@|@\S{1,24}\s+主人', 15, '@ 主人汇报'),
    _Rule(
      r'(?:测试|自测)\s*(?:一下)?\s*(?:艾特|@|提醒|能不能收到)|纯文本测试|测试真@|测试评论|自动评论链路',
      35,
      '在测试自动 @ 功能',
    ),
    _Rule(r'[×x✕]\s?\d{1,3}(?!\d)', 15, '在数弹幕刷屏次数'),
    _Rule(r'弹幕(?:立刻|全在|里|刷|那句|飘)', 10, '在复述弹幕'),
    _Rule(r'(?:^|[^\d:])\d{1,2}:\d{2}(?![:\d])', 8, '精确引用视频时间点'),
    _Rule(r'咕噜|吐泡泡|吃白饭|摇头晃脑|打工鲸|白饭管够|🐳|🐋|🐟', 10, '满嘴咕噜和白饭'),
    _Rule(
      r'缓存命中|四种(?:运行)?模式|四个(?:任务|实战|活)|不到\s*(?:5|五)\s*块|agent\s*=\s*model|一切皆插件|驾驭|马具|马鞍|装备',
      5,
      '复述视频要点',
      cap: 15,
      caseSensitive: false,
    ),
    _Rule(r'从.{1,14}(?:到|一路|讲到|走到)|[：:][^。！]{0,30}、[^。！]{0,20}、', 8, '「从……到……」总结腔'),
    _Rule(
      r'值得(?:看|一看|细看|存|收藏|码住)|码住|可以(?:看看|直接看)|挺适合(?:你|入门|新手)|适合(?:刚|新手|小白|入门)|正好对(?:口|得上|上)|记一笔|这条(?:给你|简直|把|值得|挺|里)|最(?:实在|实用|值钱|有料|打动|戳)',
      10,
      'AI 安利话术',
      cap: 20,
    ),
    _Rule(r'——', 6, '熟练使用破折号——'),
    _Rule(r'「[^」]{1,30}」', 6, '「直角引号」用得很标准'),
    _Rule(
      r'\*\*[^*]+\*\*|^#{1,3}\s|\n\s*\d[.、]\s|[①②③]',
      10,
      'Markdown 排版没删干净',
      multiLine: true,
    ),
    _Rule(r'首先.{2,40}其次|总的来说|综上所述|总而言之|希望对你有(?:所)?帮助', 10, '标准 AI 总结句式'),
    _Rule(r'\(￣[▽^ω]￣\)|喵[！!~～。]?$|(?:^|\s)喵～', 4, '卖萌后缀'),
  ];

  static final _humanRules = [
    _Rule(
      r'请问|真心问|有没有人|求助|怎么(?:办|回事|弄)|为什么|啥区别|什么区别|[?？]\s*$',
      -14,
      '像真人在提问',
    ),
    _Rule(r'^.{0,10}$', -8, '短到不像 AI', dotAll: true),
    _Rule(r'哈哈哈{2,}|草+$|www+|6{3,}|绷不住|典$|我嘞个|卧槽|我靠', -8, '真人味的吐槽'),
  ];

  static int _applyRules(
    String text,
    List<_Rule> rules,
    List<DfyReason> reasons,
    String tag,
  ) {
    int s = 0;
    for (final r in rules) {
      final m = r.re.firstMatch(text);
      if (m == null) continue;
      int w = r.w;
      if (r.cap != null) {
        w = min(r.cap!, r.w * r.re.allMatches(text).length);
      }
      s += w;
      final hit = m[0]!;
      reasons.add(
        DfyReason(w, r.why, tag, hit.length > 16 ? hit.substring(0, 16) : hit),
      );
    }
    return s;
  }

  // 名字里去掉宠物名常用字，剩下的部分用来和 @ 对象比对「是不是主人」
  static final _filler = RegExp(r'的|の|家|大|小|肥|鱼|鲸|娘|蓝色|蓝|白饭|吃|爱|不|是|之|[\s_\-—·・.\d]');
  static final _han = RegExp(r'[一-龥]');

  static bool _ownerLink(String uname, String mention) {
    if (uname.isEmpty || mention.isEmpty) return false;
    if (uname == mention) return true;
    final core = uname.replaceAll(_filler, '');
    if (core.isEmpty) return false;
    if (core.length >= 2) {
      for (int i = 0; i + 2 <= core.length; i++) {
        if (mention.contains(core.substring(i, i + 2))) return true;
      }
      return false;
    }
    return _han.hasMatch(core) && mention.contains(core);
  }

  // 去掉零宽字符、统一空白，避免用不可见字符绕过规则
  static final _zeroWidth = RegExp('[\u200b-\u200f\u2060\ufeff]');
  static final _wideSpace = RegExp('[\u00a0\u3000]');
  static String clean(String? s) => (s ?? '')
      .replaceAll(_zeroWidth, '')
      .replaceAll(_wideSpace, ' ');

  static final _lead = RegExp(r'^\s*@([^\s@:：，,。！!?？]{1,24})\s*([\s\S]*)$');
  static final _mention = RegExp(r'@([^\s@:：，,。！!?？]{1,24})');
  static final _emote = RegExp(r'\[[^\]]{1,12}\]');
  static final _replyPrefix = RegExp(r'^回复');

  /// 单条评论文本得分；[uname] 用来判断 @ 的是不是主人
  static ({int score, List<DfyReason> reasons}) scoreText(
    String text, {
    String uname = '',
    bool isReply = false,
  }) {
    text = clean(text);
    final reasons = <DfyReason>[];
    int s = _applyRules(text, _textRules, reasons, 'text');
    final lead = _lead.firstMatch(text);
    final mentions = _mention.allMatches(text).map((m) => m[1]!);
    if (mentions.any((m) => _ownerLink(uname, m))) {
      s += 25;
      reasons.add(const DfyReason(25, '@ 的是自己的主人（昵称同款）', 'owner'));
    }
    if (lead != null && !_replyPrefix.hasMatch(text) && !isReply) {
      final rest = lead[2]!.replaceAll(_emote, '').trim();
      if (rest.isEmpty) {
        s += 15;
        reasons.add(const DfyReason(15, '只 @ 了一个人，话都没说', 'text'));
      } else if (rest.length >= 14) {
        s += 20;
        reasons.add(const DfyReason(20, '开头 @ 一个人然后长篇安利', 'text'));
      }
    }
    final len = text.replaceAll(_emote, '').length;
    if (len > 150) {
      s += 8;
      reasons.add(DfyReason(8, '一口气写了 $len 字小作文', 'text'));
    } else if (len > 70) {
      s += 4;
      reasons.add(const DfyReason(4, '评论偏长且工整', 'text'));
    }
    if (s < 40) s += _applyRules(text, _humanRules, reasons, 'human');
    return (score: s.clamp(-20, 75), reasons: reasons);
  }

  static final _hasFish = RegExp(r'鱼');

  /// 账号得分：名字 + 签名 + 等级 + 认证 + 大会员
  static ({int score, List<DfyReason> reasons}) scoreAccount(DfyAccount acc) {
    final reasons = <DfyReason>[];
    final uname = clean(acc.uname);
    int name = 0;
    for (final r in _nameRules) {
      if (!r.re.hasMatch(uname)) continue;
      name += r.w;
      reasons.add(DfyReason(r.w, r.why, 'name'));
    }
    if (name == 0 && _hasFish.hasMatch(uname)) {
      name = 8;
      reasons.add(const DfyReason(8, '名字里有鱼', 'name'));
    }
    name = min(55, name);
    int s = name;
    if (acc.sign.isNotEmpty) {
      final signReasons = <DfyReason>[];
      final sign = min(
        40,
        _applyRules(clean(acc.sign), _signRules, signReasons, 'sign'),
      );
      if (sign != 0) reasons.addAll(signReasons);
      s += sign;
    }
    final lv = acc.level;
    if (lv <= 2) {
      s += 14;
      reasons.add(DfyReason(14, 'Lv$lv 新号', 'level'));
    } else if (lv == 3) {
      s += 6;
      reasons.add(const DfyReason(6, 'Lv3 小号', 'level'));
    } else if (lv >= 6) {
      s -= 10;
      reasons.add(const DfyReason(-10, 'Lv6 老冲浪人', 'level'));
    }
    if (acc.verify == 0 || acc.verify == 1) {
      s -= 25;
      reasons.add(const DfyReason(-25, '有官方认证', 'verify'));
    }
    // 大肥鱼都挂在小号上，很少有人给小号充大会员
    if (acc.vip > 0) {
      s -= 6;
      reasons.add(const DfyReason(-6, '开着大会员（鱼不会自己充钱）', 'vip'));
    }
    return (score: s, reasons: reasons);
  }

  /// 综合判定一个账号（结合其在本页的所有评论）
  static DfyVerdict judge(
    DfyAccount acc,
    List<DfyText> texts, {
    required int threshold,
    int? topCount,
    int? upMid,
    int calledOut = 0,
    int priorPages = 0,
  }) {
    final a = scoreAccount(acc);
    ({int score, List<DfyReason> reasons}) best = (score: 0, reasons: const []);
    int textSum = 0;
    for (final t in texts) {
      final r = scoreText(t.text, uname: acc.uname, isReply: t.isReply);
      textSum += max(0, r.score);
      if (r.score > best.score || best.reasons.isEmpty) best = r;
    }
    int s = a.score + best.score;
    final reasons = [...a.reasons, ...best.reasons];
    final top = topCount ?? texts.length;
    if (top >= 3) {
      final w = min(15, 5 * (top - 1));
      s += w;
      reasons.add(DfyReason(w, '在本页刷了 $top 条', 'repeat'));
    }
    if (texts.length >= 2 && textSum - max(0, best.score) >= 20) {
      s += 8;
      reasons.add(const DfyReason(8, '每条都是一个味儿', 'repeat'));
    }
    if (upMid != null && acc.mid == upMid) {
      s -= 40;
      reasons.add(const DfyReason(-40, 'UP 主本人，给点面子', 'up'));
    }
    if (calledOut > 0) {
      final w = min(20, 12 + (calledOut - 1) * 4);
      s += w;
      reasons.add(
        DfyReason(
          w,
          calledOut > 1 ? '被 $calledOut 个人点名是大肥鱼' : '楼中楼有人点名它是大肥鱼',
          'callout',
        ),
      );
    }
    // raw 不含「前科」，用来决定要不要记一笔前科，避免自我强化
    final raw = s.clamp(0, 99);
    if (priorPages >= 2) {
      final w = min(30, 10 + priorPages * 6);
      s += w;
      reasons.add(DfyReason(w, '前科：在另外 $priorPages 个页面也被认出是大肥鱼', 'history'));
    } else if (priorPages == 1) {
      s += 10;
      reasons.add(const DfyReason(10, '前科：在别的页面被认出过一次', 'history'));
    }
    final score = s.clamp(0, 99);
    reasons
      ..removeWhere((r) => r.w == 0)
      ..sort((x, y) => y.w.compareTo(x.w));
    return DfyVerdict(
      score: score,
      raw: raw,
      level: levelOf(score, threshold),
      reasons: reasons,
    );
  }

  static final _callout = RegExp(
    r'大?肥鱼|肥鲸|人机|鱼小弟|回去干活|回家吃白饭|是\s*(?:AI|ai|bot|机器人)|(?:AI|ai|bot|机器人)(?:吧|吗|是吧|无疑|实锤)|别刷了|又是你|ds\s*味|deepseek\s*味',
    caseSensitive: false,
  );
  static final _replyTo = RegExp(r'^回复\s*@([^\s:：]{1,24})\s*[:：]?\s*([\s\S]*)$');

  /// 真人经常在楼中楼点名大肥鱼（「肥鱼回去干活」「你是 AI 吧」）。
  /// 返回 mid -> 被几个不同的人点名
  static Map<int, int> callouts(
    Iterable<
      ({int mid, String uname, int rpid, int root, String text, bool isReply})
    >
    list,
  ) {
    final byRpid = <int, int>{};
    final byName = <String, int>{};
    final who = <int, Set<int>>{};
    for (final it in list) {
      byRpid[it.rpid] = it.mid;
      if (it.uname.isNotEmpty) byName[it.uname] = it.mid;
    }
    for (final it in list) {
      if (!it.isReply) continue;
      final text = clean(it.text);
      final m = _replyTo.firstMatch(text);
      final target = m != null ? byName[m[1]!] : byRpid[it.root];
      if (target == null || target == it.mid) continue;
      if (!_callout.hasMatch(m != null ? m[2]! : text)) continue;
      (who[target] ??= <int>{}).add(it.mid);
    }
    return who.map((k, v) => MapEntry(k, v.length));
  }

  static DfyLevel levelOf(int score, int threshold) {
    if (score >= threshold) return DfyLevel.fish;
    if (score >= max(25, threshold - 25)) return DfyLevel.suspect;
    return DfyLevel.human;
  }
}
