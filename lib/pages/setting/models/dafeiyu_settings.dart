import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/slider_dialog.dart';
import 'package:PiliPlus/utils/dafeiyu/dafeiyu.dart';
import 'package:PiliPlus/utils/dafeiyu/dafeiyu_llm.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 大肥鱼消除计划 (ported from liyupi/dafeiyu-cleaner)
List<SettingsModel> get dafeiyuSettings => [
  SwitchModel(
    title: '大肥鱼消除计划',
    subtitle: '离线识别评论区里 DeepSeek 等 AI 驱动的机器人账号（大肥鱼），仅本地标记，不删评论、不举报',
    leading: const Text('🐟', style: TextStyle(fontSize: 20)),
    setKey: SettingBoxKey.dfyEnable,
    defaultVal: true,
    onChanged: (value) => Dafeiyu.enable = value,
  ),
  NormalModel(
    title: '大肥鱼处理方式',
    leading: const Icon(Icons.cleaning_services_outlined),
    getSubtitle: () => '当前：${Dafeiyu.action.label}（可疑账号只标记，不折叠/隐藏）',
    onTap: (context, setState) async {
      final res = await showDialog<DfyAction>(
        context: context,
        builder: (context) => SelectDialog<DfyAction>(
          title: '大肥鱼处理方式',
          value: Dafeiyu.action,
          values: DfyAction.values.map((e) => (e, e.label)).toList(),
        ),
      );
      if (res != null) {
        Dafeiyu.action = res;
        await GStorage.setting.put(SettingBoxKey.dfyAction, res.index);
        setState();
        SmartDialog.showToast('刷新评论区后生效');
      }
    },
  ),
  NormalModel(
    title: '大肥鱼识别严格度',
    leading: const Icon(Icons.tune),
    getSubtitle: () =>
        '当前：${Dafeiyu.threshold} 分以上判为大肥鱼，${Dafeiyu.threshold - 25 < 25 ? 25 : Dafeiyu.threshold - 25} 分以上为可疑（默认 60，越低越严）',
    onTap: (context, setState) async {
      final res = await showDialog<double>(
        context: context,
        builder: (context) => SliderDialog(
          title: const Text('大肥鱼判定阈值'),
          min: 40,
          max: 90,
          divisions: 10,
          precise: 0,
          value: Dafeiyu.threshold.toDouble(),
        ),
      );
      if (res != null) {
        Dafeiyu.threshold = res.toInt();
        await GStorage.setting.put(SettingBoxKey.dfyThreshold, res.toInt());
        setState();
      }
    },
  ),
  NormalModel(
    title: '大肥鱼名单',
    leading: const Icon(Icons.list_alt),
    getSubtitle: () =>
        '遣返名单 ${Dafeiyu.sentHome.length} 个，人类白名单 ${Dafeiyu.whitelist.length} 个',
    onTap: (context, setState) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('大肥鱼名单'),
          content: Text(
            '遣返名单：${Dafeiyu.sentHome.length} 个账号（手动赶走的，以后一律按大肥鱼处理）\n'
            '人类白名单：${Dafeiyu.whitelist.length} 个账号（点过「是人类」的，不再标记）\n\n'
            '单个账号可在评论长按菜单 →「大肥鱼鉴定」里改判。',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Get.back();
                Dafeiyu.clearLists();
                setState();
                SmartDialog.showToast('已清空');
              },
              child: Text(
                '全部清空',
                style: TextStyle(color: ColorScheme.of(context).error),
              ),
            ),
            TextButton(onPressed: Get.back, child: const Text('关闭')),
          ],
        ),
      );
    },
  ),
  SwitchModel(
    title: 'DeepSeek 精判',
    subtitle: '离线规则拿不准的账号交给 DeepSeek 再判一次（需自备 API Key，只发送可疑账号的昵称、等级和最多 3 条评论到 api.deepseek.com，结果缓存 7 天）',
    leading: const Icon(Icons.psychology_outlined),
    setKey: SettingBoxKey.dfyLlmEnable,
    defaultVal: false,
    onChanged: (value) {
      Dafeiyu.llmEnable = value;
      Dafeiyu.tick.value++;
    },
  ),
  NormalModel(
    title: 'DeepSeek API Key',
    leading: const Icon(Icons.key_outlined),
    getSubtitle: () {
      final key = Dafeiyu.llmKey;
      if (key.isEmpty) return '未设置，到 platform.deepseek.com 申请';
      return '已设置：${key.length > 8 ? '${key.substring(0, 5)}…${key.substring(key.length - 4)}' : '****'}';
    },
    onTap: _showKeyDialog,
  ),
  NormalModel(
    title: 'DeepSeek 模型',
    leading: const Icon(Icons.memory_outlined),
    getSubtitle: () =>
        DfyLlm.models
            .firstWhere(
              (e) => e.$1 == Dafeiyu.llmModel,
              orElse: () => (Dafeiyu.llmModel, Dafeiyu.llmModel),
            )
            .$2,
    onTap: (context, setState) async {
      final res = await showDialog<String>(
        context: context,
        builder: (context) => SelectDialog<String>(
          title: 'DeepSeek 模型',
          value: Dafeiyu.llmModel,
          values: DfyLlm.models,
        ),
      );
      if (res != null) {
        Dafeiyu.llmModel = res;
        await GStorage.setting.put(SettingBoxKey.dfyLlmModel, res);
        setState();
      }
    },
  ),
  SwitchModel(
    title: '自动精判可疑账号',
    subtitle: '关闭后只能在「大肥鱼鉴定」弹窗里手动精判',
    leading: const Icon(Icons.auto_awesome_outlined),
    setKey: SettingBoxKey.dfyLlmAuto,
    defaultVal: true,
    onChanged: (value) => Dafeiyu.llmAuto = value,
  ),
  NormalModel(
    title: '清空精判缓存',
    leading: const Icon(Icons.delete_sweep_outlined),
    getSubtitle: () => '已缓存 ${Dafeiyu.llmCacheSize} 个账号的精判结果',
    onTap: (context, setState) {
      Dafeiyu.clearLlmCache();
      setState();
      SmartDialog.showToast('已清空');
    },
  ),
];

void _showKeyDialog(BuildContext context, VoidCallback setState) {
  final controller = TextEditingController(text: Dafeiyu.llmKey);
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('DeepSeek API Key'),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(hintText: 'sk-...'),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final key = controller.text.trim();
            if (key.isEmpty) {
              SmartDialog.showToast('先填入密钥');
              return;
            }
            SmartDialog.showLoading(msg: '连接中…');
            final res = await DfyLlm.testKey(key, Dafeiyu.llmModel);
            SmartDialog.dismiss();
            SmartDialog.showToast(res.msg);
          },
          child: const Text('测试'),
        ),
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            final key = controller.text.trim();
            Get.back();
            Dafeiyu.llmKey = key;
            await GStorage.setting.put(SettingBoxKey.dfyLlmKey, key);
            setState();
          },
          child: const Text('保存'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}
