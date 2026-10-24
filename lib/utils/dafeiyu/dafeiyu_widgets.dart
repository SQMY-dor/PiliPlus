import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/utils/dafeiyu/dafeiyu.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const _fishColor = Color(0xFFE5484D);
const _suspectColor = Color(0xFFE5A100);

Color dfyColor(DfyLevel level) =>
    level == DfyLevel.fish ? _fishColor : _suspectColor;

/// 「大肥鱼 92%」贴纸，点按查看鉴定依据
class DfyBadge extends StatelessWidget {
  const DfyBadge({
    super.key,
    required this.item,
    required this.verdict,
    this.onSendHome,
    this.onChanged,
  });

  final ReplyInfo item;
  final DfyVerdict verdict;
  final VoidCallback? onSendHome;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final color = dfyColor(verdict.level);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showDfyReport(
        context,
        item: item,
        verdict: verdict,
        onSendHome: onSendHome,
        onChanged: onChanged,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 0.8),
          borderRadius: const BorderRadius.all(Radius.circular(3)),
        ),
        child: Text(
          '${verdict.level == DfyLevel.fish ? '🐟 ' : ''}${verdict.level.label} ${verdict.score}%${verdict.llmAi != null ? ' · DS' : ''}',
          style: TextStyle(fontSize: 9, height: 1.2, color: color),
          textScaler: TextScaler.noScaling,
        ),
      ),
    );
  }
}

/// 折叠条：「这条大肥鱼在家吃白饭，点按展开」
class DfyFoldBar extends StatelessWidget {
  const DfyFoldBar({
    super.key,
    required this.verdict,
    required this.onExpand,
  });

  final DfyVerdict verdict;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Material(
      color: colorScheme.onInverseSurface,
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        onTap: onExpand,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            '🍚 疑似 AI 大肥鱼（${verdict.score}%），已折叠，点按展开',
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
        ),
      ),
    );
  }
}

void showDfyReport(
  BuildContext context, {
  required ReplyInfo item,
  required DfyVerdict verdict,
  VoidCallback? onSendHome,
  VoidCallback? onChanged,
}) {
  final mid = item.mid.toInt();
  final parentContext = context;
  showDialog(
    context: context,
    builder: (context) {
      final colorScheme = ColorScheme.of(context);
      final color = dfyColor(verdict.level);
      return AlertDialog(
        title: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${verdict.level.label} ${verdict.score}%',
                style: TextStyle(color: color),
              ),
              TextSpan(
                text: '  ${item.member.name}',
                style: TextStyle(fontSize: 14, color: colorScheme.outline),
              ),
            ],
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in verdict.reasons)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 38,
                        child: Text(
                          r.w > 0 ? '+${r.w}' : '${r.w}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: r.w > 0 ? _fishColor : Colors.green,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: r.why),
                              if (r.hit != null && r.hit!.isNotEmpty)
                                TextSpan(
                                  text: '  「${r.hit}」',
                                  style: TextStyle(
                                    color: colorScheme.outline,
                                  ),
                                ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              if (verdict.llmAi != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4D6BFE).withValues(alpha: 0.12),
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text:
                              'DeepSeek 精判 · AI 概率 ${verdict.llmAi}%'
                              '${verdict.offline != null ? ' · 离线 ${verdict.offline}%' : ''}\n',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4D6BFE),
                          ),
                        ),
                        TextSpan(text: verdict.llmReason ?? ''),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                verdict.llmAi != null
                    ? '最终分 = 离线 45% + DeepSeek 55%，仅在本机标记，不会删评论或举报。'
                    : '离线规则判定，仅在本机标记，不会删评论或举报。',
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
              ),
            ],
          ),
        ),
        actions: [
          if (Dafeiyu.canLlm && verdict.llmAi == null)
            TextButton(
              onPressed: () async {
                Get.back();
                final v = await Dafeiyu.judgeNow(item);
                if (v != null && parentContext.mounted) {
                  onChanged?.call();
                  showDfyReport(
                    parentContext,
                    item: item,
                    verdict: v,
                    onSendHome: onSendHome,
                    onChanged: onChanged,
                  );
                }
              },
              child: const Text('DeepSeek 精判'),
            ),
          TextButton(
            onPressed: () {
              Get.back();
              Dafeiyu.markHuman(mid);
              onChanged?.call();
              SmartDialog.showToast('已标记为人类，以后不再标记 TA');
            },
            child: const Text('是人类'),
          ),
          if (onSendHome != null)
            TextButton(
              onPressed: () {
                Get.back();
                Dafeiyu.sendHome(mid);
                onSendHome();
                SmartDialog.showToast('已赶回家吃白饭 🍚');
              },
              child: Text('赶回家吃白饭', style: TextStyle(color: color)),
            ),
          TextButton(
            onPressed: Get.back,
            child: Text('关闭', style: TextStyle(color: colorScheme.outline)),
          ),
        ],
      );
    },
  );
}
