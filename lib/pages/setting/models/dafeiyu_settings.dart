import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/slider_dialog.dart';
import 'package:PiliPlus/utils/dafeiyu/dafeiyu.dart';
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
];
