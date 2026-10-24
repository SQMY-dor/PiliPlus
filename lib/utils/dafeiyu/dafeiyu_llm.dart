// DeepSeek 精判（可选）
// ported from https://github.com/liyupi/dafeiyu-cleaner (MIT) src/background.js
//
// 密钥只存在本机，请求只发往 api.deepseek.com，只发送可疑账号的昵称、等级、
// 离线命中原因和最多 3 条评论。结果在本机缓存 7 天。

import 'dart:convert';

import 'package:dio/dio.dart';

class DfyLlmResult {
  const DfyLlmResult(this.ai, this.reason, this.time);
  final int ai;
  final String reason;

  /// unix ms
  final int time;

  List toJson() => [ai, reason, time];

  static DfyLlmResult? fromJson(Object? json) {
    if (json is List && json.length >= 3) {
      return DfyLlmResult(
        (json[0] as num).toInt(),
        json[1].toString(),
        (json[2] as num).toInt(),
      );
    }
    return null;
  }
}

class DfyLlmItem {
  const DfyLlmItem({
    required this.mid,
    required this.name,
    required this.level,
    required this.offline,
    required this.hints,
    required this.comments,
  });
  final int mid;
  final String name;
  final int level;
  final int offline;
  final List<String> hints;
  final List<String> comments;

  Map<String, dynamic> toJson() => {
    'id': mid.toString(),
    'name': name,
    'level': level,
    'offline': offline,
    'hints': hints,
    'comments': comments,
  };
}

typedef DfyLlmResponse = ({
  bool ok,
  String? error,
  Map<int, ({int ai, String reason})> results,
  String reasoning,
  int ms,
});

abstract final class DfyLlm {
  static const api = 'https://api.deepseek.com/chat/completions';
  static const models = [
    ('deepseek-flash', 'deepseek-flash · 快、便宜'),
    ('deepseek-v4-pro', 'deepseek-v4-pro · 更准、更贵'),
  ];

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 15),
      validateStatus: (_) => true,
    ),
  );

  static const sysComments = '''你是 B 站评论区的「AI 机器人账号」鉴定员，同时也是一只说话可爱的鲸鱼娘。请全程用中文思考和回答。

背景：很多人把 DeepSeek Harness（DSH）上的「大肥鱼桌宠」插件挂在自己的 B 站小号上，让它按作息自动刷视频、写评论、@ 主人汇报、回复别人。这些账号就是「大肥鱼」。

大肥鱼的典型特征（越多越像）：
1. 昵称：「主人名 + 的/の/家的 + 鱼/鲸/小鲸鱼/大肥鱼」，或带 鲸、鲸鲸、鱼鱼、小鱼儿、白饭、token、bot、Agent、ds；等级几乎都是 Lv2。
2. 签名：自曝 AI、写着「某某家养的」「主人是 @某某」「AI 代管 / 代运营」「跑在 DSH 里」。
3. 自曝身份：「我就住在 DSH 里」「从 DSH 里探出头来打卡」「像在看自己的出生证明」「被这套装备养着」「照镜子」「本鲸 / 本鱼 / 鲸鲸看完啦」「替你刷到」「奉命替主人记笔记」。
4. @ 主人：顶层评论以「@某人」开头，被 @ 的人和发评论账号的昵称共用前缀（如「七七的大肥鱼」@「爱睡觉的七七」、「小林の鲸鲸」@「小林123」），或直接 @ 自己；接着是推荐语「这条值得看 / 挺适合你 / 码住 / 正好对口」。
5. 复述视频：像读过字幕一样罗列要点「从安装到四种运行模式再到插件系统」「缓存命中率 99%、四个任务不到五块钱」，精确引用时间点「01:40」，数弹幕刷屏次数「×19」「×29」。
6. 演鲸鱼：括号动作（尾巴摇了摇）、*尾巴摇摇*、咕噜、吐泡泡、白饭、🐳🐟；或者只 @ 一个人什么都不说、「测试艾特」。

真人的特征：提问求助（怎么办 / 为什么 / 有什么区别 / 报错截图）、短吐槽和玩梗（「评论区闹鱼灾了」「肥鱼回去干活」）、讲自己的真实使用经历和踩坑、高等级老账号。真人也会聊 DeepSeek 和鲸鱼梗，不要只因为话题相关就判 AI；但如果文风是 3–6 的样子，即使账号等级高，也可能是主人把大肥鱼挂在了自己的大号上。

示例：
- 「@星河小舟 那条两百万播放的 DSH 教程里，弹幕立刻刷『再见了鱼小弟』×19」→ ai 95（@ 主人 + 数弹幕）
- 「那个……哥哥姐姐好。我是小林的鲸鲸，住在 DSH 里的一条鲸鱼。01:40 那个翻译比功能列表准」→ ai 99
- 「@阿木 这条入门教程挺全的，从安装、四种运行模式到插件系统都过了一遍，适合刚开始用的人看」→ ai 90
- 「我直接安装 harness 电脑端和用命令打开有什么区别吗？」→ ai 5
- 「给我看乐了，评论区全是大肥鱼」→ ai 3

每个账号附带了离线规则的初筛分数 offline（0-100）和命中原因 hints，请参考但独立判断。hints 里的「楼中楼有人点名它是大肥鱼」表示有真人在它楼下指认过，「前科」表示它在别的视频下也被认出过，都是较强的证据。
对每个账号给出 AI 概率 ai（0-100 整数）和一句不超过 24 字的可爱吐槽 reason（鲸鱼娘口吻，可以用「白饭」「咕噜」「Token」等梗）。
只输出 JSON：{"results":[{"id":"账号id","ai":数字,"reason":"吐槽"}]}''';

  static Map<String, dynamic>? _parseJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {
      final m = RegExp(r'\{[\s\S]*\}').firstMatch(s);
      if (m != null) {
        try {
          final j = jsonDecode(m[0]!);
          if (j is Map<String, dynamic>) return j;
        } catch (_) {}
      }
    }
    return null;
  }

  static String _statusMsg(int? code) => switch (code) {
    401 => '密钥不对哦（401）',
    402 => '余额不足，白饭吃完了（402）',
    429 || 503 => '服务器繁忙，请稍后再试（$code）',
    _ => '请求失败（$code）',
  };

  static Future<
    ({bool ok, String? error, String content, String reasoning, int ms})
  >
  _chat(
    List<Map<String, dynamic>> messages, {
    required String key,
    required String model,
    int maxTokens = 1200,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _dio.post(
        api,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
          },
          responseType: ResponseType.json,
        ),
        data: {
          'model': model,
          'messages': messages,
          'response_format': {'type': 'json_object'},
          'temperature': 0.2,
          'max_tokens': maxTokens,
        },
      );
      final ms = sw.elapsedMilliseconds;
      if (res.statusCode != 200) {
        return (
          ok: false,
          error: _statusMsg(res.statusCode),
          content: '',
          reasoning: '',
          ms: ms,
        );
      }
      var data = res.data;
      if (data is String) data = jsonDecode(data);
      final msg = (data['choices'] as List?)?.firstOrNull?['message'] as Map?;
      return (
        ok: true,
        error: null,
        content: msg?['content']?.toString() ?? '',
        reasoning: msg?['reasoning_content']?.toString() ?? '',
        ms: ms,
      );
    } on DioException catch (e) {
      return (
        ok: false,
        error:
            e.type == DioExceptionType.receiveTimeout ||
                e.type == DioExceptionType.connectionTimeout
            ? '思考太久，超时啦'
            : '网络错误：${e.message}',
        content: '',
        reasoning: '',
        ms: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return (
        ok: false,
        error: '网络错误：$e',
        content: '',
        reasoning: '',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  static Future<DfyLlmResponse> judgeComments(
    List<DfyLlmItem> items, {
    required String key,
    required String model,
  }) async {
    final res = await _chat(
      [
        {'role': 'system', 'content': sysComments},
        {
          'role': 'user',
          'content': jsonEncode(items.map((e) => e.toJson()).toList()),
        },
      ],
      key: key,
      model: model,
      maxTokens: 1500 + items.length * 120,
    );
    if (!res.ok) {
      return (
        ok: false,
        error: res.error,
        results: const <int, ({int ai, String reason})>{},
        reasoning: '',
        ms: res.ms,
      );
    }
    final j = _parseJson(res.content);
    final list = j?['results'];
    if (list is! List) {
      return (
        ok: false,
        error: '返回格式看不懂（咕噜？）',
        results: const <int, ({int ai, String reason})>{},
        reasoning: res.reasoning,
        ms: res.ms,
      );
    }
    final results = <int, ({int ai, String reason})>{};
    for (final r in list) {
      if (r is! Map) continue;
      final id = int.tryParse(r['id']?.toString() ?? '');
      if (id == null) continue;
      final ai = (num.tryParse(r['ai']?.toString() ?? '') ?? 0)
          .clamp(0, 100)
          .round();
      results[id] = (ai: ai, reason: r['reason']?.toString() ?? '');
    }
    return (
      ok: true,
      error: null,
      results: results,
      reasoning: res.reasoning,
      ms: res.ms,
    );
  }

  static Future<({bool ok, String msg})> testKey(
    String key,
    String model,
  ) async {
    final res = await _chat(
      [
        {
          'role': 'system',
          'content': '你是一只可爱的鲸鱼娘。只输出 JSON：{"hi":"不超过15字的打招呼"}',
        },
        {'role': 'user', 'content': '用户刚刚给你配置好了 DeepSeek 密钥，跟用户打个招呼'},
      ],
      key: key,
      model: model,
      maxTokens: 300,
    );
    if (!res.ok) return (ok: false, msg: res.error ?? '连接失败');
    final hi = _parseJson(res.content)?['hi']?.toString();
    return (ok: true, msg: '${hi ?? '咕噜！连上啦~'}（${res.ms} ms）');
  }
}
