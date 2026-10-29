import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/dm_midhash.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 视频弹幕统计 / 下载 / 查询发送者
/// 参考 bilibili 视频弹幕统计|下载|查询发送者 (ZBpine/bili-danmaku-statistic)
class DanmakuStatPage extends StatefulWidget {
  const DanmakuStatPage({
    super.key,
    required this.cid,
    required this.durationSec,
    this.title,
    this.bvid,
  });

  final int cid;
  final int durationSec;
  final String? title;
  final String? bvid;

  static void open({
    required int cid,
    required int durationSec,
    String? title,
    String? bvid,
  }) {
    Get.to(
      () => DanmakuStatPage(
        cid: cid,
        durationSec: durationSec,
        title: title,
        bvid: bvid,
      ),
    );
  }

  @override
  State<DanmakuStatPage> createState() => _DanmakuStatPageState();
}

class _UserStat {
  _UserStat(this.hash);
  final String hash;
  int count = 0;
  int firstCtime = 1 << 62;
  int lastCtime = 0;
}

class _DanmakuStatPageState extends State<DanmakuStatPage> {
  /// 全部已加载弹幕（按 id 去重）
  List<DanmakuElem> _all = [];

  /// 当前筛选后的弹幕
  List<DanmakuElem> _list = [];

  bool _loading = false;
  String? _error;
  String _progressText = '';

  /// null 为实时弹幕，否则为历史弹幕日期
  DateTime? _historyDate;

  final _regexCtr = TextEditingController();
  RegExp? _regex;
  String? _regexError;
  bool _exclude = false;

  /// 选中的用户 midHash
  String? _selectedUser;

  late final String? _myHash = Accounts.main.isLogin
      ? DmMidHash.hashOf(Accounts.main.mid)
      : null;

  // 统计结果
  List<_UserStat> _users = [];
  List<MapEntry<String, int>> _repeat = [];
  List<MapEntry<String, int>> _words = [];
  List<int> _density = [];
  List<MapEntry<String, int>> _dates = [];
  List<int> _hours = List.filled(24, 0);
  Map<String, int> _modes = {};

  /// midHash -> 反查结果缓存
  final Map<String, List<int>> _crackCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _regexCtr.dispose();
    super.dispose();
  }

  int get _segCount =>
      math.max(1, (widget.durationSec * 1000 / (6 * 60 * 1000)).ceil());

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _progressText = '';
    });
    final map = <String, DanmakuElem>{};
    void addAll(Iterable<DanmakuElem> elems) {
      for (final e in elems) {
        final key = e.idStr.isNotEmpty ? e.idStr : e.id.toString();
        map[key] = e;
      }
    }

    try {
      if (_historyDate == null) {
        final total = _segCount;
        var done = 0;
        var failed = 0;
        // 并发 3 段
        final queue = List.generate(total, (i) => i + 1);
        Future<void> worker() async {
          while (queue.isNotEmpty) {
            final seg = queue.removeAt(0);
            final res = await DmGrpc.dmSegMobile(
              cid: widget.cid,
              segmentIndex: seg,
            );
            if (res case Success(:final response)) {
              addAll(response.elems);
            } else {
              failed++;
            }
            done++;
            if (mounted) {
              setState(() => _progressText = '加载分段 $done/$total');
            }
          }
        }

        await Future.wait(List.generate(math.min(3, total), (_) => worker()));
        if (map.isEmpty && failed > 0) {
          throw '弹幕加载失败';
        }
      } else {
        if (!Accounts.main.isLogin) {
          throw '历史弹幕需要登录';
        }
        final d = _historyDate!;
        final date =
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        setState(() => _progressText = '加载 $date 历史弹幕');
        final res = await Request().get(
          'https://api.bilibili.com/x/v2/dm/web/history/seg.so',
          queryParameters: {'type': 1, 'oid': widget.cid, 'date': date},
          options: Options(responseType: ResponseType.bytes),
        );
        final data = res.data;
        if (data is List<int>) {
          final bytes = Uint8List.fromList(
            Request.responseBytesDecoder(data, res.headers.map),
          );
          // 出错时接口返回 JSON
          if (bytes.isNotEmpty && bytes.first == 0x7B) {
            final json = jsonDecode(utf8.decode(bytes));
            throw json['message'] ?? '历史弹幕加载失败';
          }
          addAll(DmSegMobileReply.fromBuffer(bytes).elems);
        } else if (data is Map) {
          throw data['message'] ?? '历史弹幕加载失败';
        } else {
          throw '历史弹幕加载失败';
        }
      }
      _all = map.values.toList()
        ..sort((a, b) => a.progress.compareTo(b.progress));
      _applyFilter();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  void _onRegexChanged(String text) {
    if (text.isEmpty) {
      _regex = null;
      _regexError = null;
    } else {
      try {
        _regex = RegExp(text, caseSensitive: false);
        _regexError = null;
      } catch (_) {
        _regex = RegExp(RegExp.escape(text), caseSensitive: false);
        _regexError = '正则无效，按普通文本匹配';
      }
    }
    _applyFilter();
    setState(() {});
  }

  void _applyFilter() {
    final regex = _regex;
    final user = _selectedUser;
    _list = _all.where((e) {
      if (user != null && e.midHash != user) return false;
      if (regex != null) {
        final hit = regex.hasMatch(e.content);
        if (hit == _exclude) return false;
      }
      return true;
    }).toList();
    _computeStats();
  }

  static final _punct = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

  void _computeStats() {
    final users = <String, _UserStat>{};
    final repeat = <String, int>{};
    final words = <String, int>{};
    final dur = math.max(1, widget.durationSec) * 1000;
    final density = List.filled(60, 0);
    final dates = <String, int>{};
    final hours = List.filled(24, 0);
    final modes = <String, int>{};

    for (final e in _list) {
      final ctime = e.ctime.toInt();
      (users[e.midHash] ??= _UserStat(e.midHash))
        ..count += 1
        ..firstCtime = math.min(users[e.midHash]!.firstCtime, ctime)
        ..lastCtime = math.max(users[e.midHash]!.lastCtime, ctime);

      final content = e.content.trim();
      repeat[content] = (repeat[content] ?? 0) + 1;

      // 2 字片段词频（每条弹幕内去重）
      final clean = content.replaceAll(_punct, '');
      final seen = <String>{};
      final runes = clean.runes.toList();
      for (var i = 0; i + 1 < runes.length; i++) {
        final w = String.fromCharCodes(runes, i, i + 2);
        if (seen.add(w)) words[w] = (words[w] ?? 0) + 1;
      }

      final bucket = (e.progress * 60 ~/ dur).clamp(0, 59).toInt();
      density[bucket]++;

      if (ctime > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ctime * 1000);
        final key =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        dates[key] = (dates[key] ?? 0) + 1;
        hours[dt.hour]++;
      }

      final mode = switch (e.mode) {
        4 => '底部',
        5 => '顶部',
        6 => '逆向',
        7 => '高级',
        8 => '代码',
        9 => 'BAS',
        _ => '滚动',
      };
      modes[mode] = (modes[mode] ?? 0) + 1;
    }

    _users = users.values.toList()..sort((a, b) => b.count.compareTo(a.count));
    _repeat =
        (repeat.entries.where((e) => e.value > 1).toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(100)
            .toList();
    _words =
        (words.entries.where((e) => e.value > 1).toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(100)
            .toList();
    _density = density;
    _dates = dates.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    _hours = hours;
    _modes = modes;
  }

  static String _fmtProgress(int ms) {
    final s = ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static String _fmtCtime(int ctime) {
    if (ctime <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ctime * 1000);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}';
  }

  Future<void> _pickHistory() async {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('历史弹幕需要登录');
      return;
    }
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _historyDate ?? now,
      firstDate: DateTime(2009, 6, 26),
      lastDate: now,
      helpText: '选择历史弹幕日期',
    );
    if (date == null) return;
    _historyDate = date;
    _selectedUser = null;
    _load();
  }

  void _useRealtime() {
    if (_historyDate == null) return;
    _historyDate = null;
    _selectedUser = null;
    _load();
  }

  Future<void> _crack(String hash) async {
    List<int>? cached = _crackCache[hash];
    if (cached == null) {
      SmartDialog.showLoading(msg: '反查中（最多 11 位 UID）');
      try {
        final List<int> r = await compute(
          DmMidHash.crackArgs,
          <Object>[hash, 11],
        );
        _crackCache[hash] = r;
        cached = r;
      } finally {
        SmartDialog.dismiss();
      }
    }
    if (!mounted) return;
    final List<int> list = cached ?? const [];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('midHash $hash'),
        content: list.isEmpty
            ? const Text('未找到匹配 UID。\n可能是 12 位以上的新 UID，无法暴力反查。')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (list.length > 1)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('有多个候选（哈希碰撞），位数越短通常越可信：'),
                    ),
                  ...list.map(
                    (mid) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('UID $mid'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Get.back();
                        Get.toNamed('/member?mid=$mid');
                      },
                      onLongPress: () => Utils.copyText(mid.toString()),
                    ),
                  ),
                ],
              ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('关闭')),
        ],
      ),
    );
  }

  void _selectUser(String? hash) {
    _selectedUser = hash;
    _applyFilter();
    setState(() {});
  }

  String get _fileBase {
    final t = (widget.title ?? widget.bvid ?? 'danmaku').replaceAll(
      RegExp(r'[\\/:*?"<>|\s]+'),
      '_',
    );
    final suffix = _historyDate == null
        ? ''
        : '_${_historyDate!.toIso8601String().substring(0, 10)}';
    return '${t}_${widget.cid}$suffix';
  }

  Future<void> _export(String type) async {
    if (_list.isEmpty) {
      SmartDialog.showToast('没有弹幕');
      return;
    }
    late final String text;
    if (type == 'json') {
      text = const JsonEncoder.withIndent('  ').convert(
        _list
            .map(
              (e) => {
                'id': e.idStr.isNotEmpty ? e.idStr : e.id.toString(),
                'progress': e.progress,
                'mode': e.mode,
                'fontsize': e.fontsize,
                'color': e.color,
                'midHash': e.midHash,
                'content': e.content,
                'ctime': e.ctime.toInt(),
                'weight': e.weight,
                'pool': e.pool,
              },
            )
            .toList(),
      );
    } else {
      final sb = StringBuffer()
        ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
        ..writeln('<i>')
        ..writeln('<chatserver>chat.bilibili.com</chatserver>')
        ..writeln('<chatid>${widget.cid}</chatid>');
      for (final e in _list) {
        final p = [
          (e.progress / 1000).toStringAsFixed(5),
          e.mode,
          e.fontsize,
          e.color,
          e.ctime.toInt(),
          e.pool,
          e.midHash,
          e.idStr.isNotEmpty ? e.idStr : e.id.toString(),
          e.weight,
        ].join(',');
        sb.writeln('<d p="$p">${_xmlEscape(e.content)}</d>');
      }
      sb.writeln('</i>');
      text = sb.toString();
    }
    await StorageUtils.saveBytes2File(
      name: '$_fileBase.$type',
      bytes: Uint8List.fromList(utf8.encode(text)),
      allowedExtensions: [type],
    );
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      // 去除 XML 不允许的控制字符
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _historyDate == null
                ? '弹幕统计'
                : '历史弹幕 ${_historyDate!.toIso8601String().substring(0, 10)}',
          ),
          actions: [
            IconButton(
              tooltip: '历史弹幕',
              onPressed: _loading ? null : _pickHistory,
              icon: const Icon(Icons.history),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'realtime':
                    _useRealtime();
                  case 'reload':
                    _load();
                  case 'json':
                  case 'xml':
                    _export(v);
                }
              },
              itemBuilder: (_) => [
                if (_historyDate != null)
                  const PopupMenuItem(value: 'realtime', child: Text('切回实时弹幕')),
                const PopupMenuItem(value: 'reload', child: Text('重新加载')),
                const PopupMenuItem(value: 'json', child: Text('下载当前弹幕 JSON')),
                const PopupMenuItem(value: 'xml', child: Text('下载当前弹幕 XML')),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '用户'),
              Tab(text: '弹幕'),
              Tab(text: '词频'),
              Tab(text: '分布'),
            ],
          ),
        ),
        body: _loading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_progressText),
                  ],
                ),
              )
            : _error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  _buildFilterBar(theme),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildUsers(theme),
                        _buildDanmakuList(theme),
                        _buildWords(theme),
                        _buildCharts(theme),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    final users = _list.map((e) => e.midHash).toSet().length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _regexCtr,
                  onChanged: _onRegexChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '正则筛选弹幕，如 前方|高能',
                    errorText: _regexError,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('排除'),
                selected: _exclude,
                onSelected: (v) {
                  _exclude = v;
                  _applyFilter();
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '弹幕 ${_list.length}/${_all.length} · 用户 $users',
                style: theme.textTheme.bodySmall,
              ),
              if (_selectedUser != null)
                InputChip(
                  label: Text('用户 $_selectedUser'),
                  onDeleted: () => _selectUser(null),
                  onPressed: () => _crack(_selectedUser!),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUsers(ThemeData theme) {
    if (_users.isEmpty) return const Center(child: Text('没有数据'));
    final max = _users.first.count;
    return ListView.builder(
      itemCount: _users.length,
      itemBuilder: (context, i) {
        final u = _users[i];
        final isMe = u.hash == _myHash;
        return ListTile(
          dense: true,
          leading: SizedBox(
            width: 32,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge,
            ),
          ),
          title: Row(
            children: [
              Text(u.hash),
              if (isMe) ...[
                const SizedBox(width: 6),
                Text('我', style: TextStyle(color: theme.colorScheme.primary)),
              ],
            ],
          ),
          subtitle: LinearProgressIndicator(
            value: u.count / max,
            minHeight: 3,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${u.count} 条'),
              IconButton(
                tooltip: '反查 UID',
                icon: const Icon(Icons.person_search, size: 20),
                onPressed: () => _crack(u.hash),
              ),
            ],
          ),
          onTap: () {
            _selectUser(u.hash);
            DefaultTabController.of(context).animateTo(1);
          },
        );
      },
    );
  }

  Widget _buildDanmakuList(ThemeData theme) {
    if (_list.isEmpty) return const Center(child: Text('没有数据'));
    final outline = theme.colorScheme.outline;
    return ListView.builder(
      itemCount: _list.length,
      itemBuilder: (context, i) {
        final e = _list[i];
        return InkWell(
          onTap: () => _showElem(e),
          onLongPress: () => Utils.copyText(e.content),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 58,
                  child: Text(
                    _fmtProgress(e.progress),
                    style: TextStyle(color: outline, fontSize: 12),
                  ),
                ),
                Expanded(child: Text(e.content)),
                const SizedBox(width: 8),
                Text(
                  e.midHash,
                  style: TextStyle(color: outline, fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showElem(DanmakuElem e) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: SelectableText(
          '${e.content}\n\n'
          '时间：${_fmtProgress(e.progress)}\n'
          '发送：${_fmtCtime(e.ctime.toInt())}\n'
          'midHash：${e.midHash}\n'
          '模式：${e.mode}  字号：${e.fontsize}  弹幕池：${e.pool}  屏蔽等级：${e.weight}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              _selectUser(e.midHash);
            },
            child: const Text('只看此人'),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              _crack(e.midHash);
            },
            child: const Text('反查 UID'),
          ),
        ],
      ),
    );
  }

  Widget _buildWords(ThemeData theme) {
    if (_repeat.isEmpty && _words.isEmpty) {
      return const Center(child: Text('没有数据'));
    }
    Widget section(String title, List<MapEntry<String, int>> data) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Text(title, style: theme.textTheme.titleSmall),
          ),
          if (data.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Text('无'),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: data.map((e) {
                final scale = data.first.value == 0
                    ? 0.0
                    : e.value / data.first.value;
                return ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    '${e.key}  ${e.value}',
                    style: TextStyle(fontSize: 12 + 6 * scale),
                  ),
                  onPressed: () {
                    _regexCtr.text = RegExp.escape(e.key);
                    _onRegexChanged(_regexCtr.text);
                  },
                );
              }).toList(),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        section('重复弹幕 Top', _repeat),
        section('高频词（2 字片段）', _words),
      ],
    );
  }

  Widget _buildCharts(ThemeData theme) {
    if (_list.isEmpty) return const Center(child: Text('没有数据'));
    final color = theme.colorScheme.primary;
    final segMs = math.max(1, widget.durationSec) * 1000 / 60;
    final dates = _dates.length > 90
        ? _dates.sublist(_dates.length - 90)
        : _dates;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      children: [
        Text('视频进度密度（每格 ${_fmtProgress(segMs.round())}）',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        _Bars(
          values: _density,
          color: color,
          labelOf: (i) =>
              '${_fmtProgress((i * segMs).round())} · ${_density[i]} 条',
        ),
        Text(
          '00:00 → ${_fmtProgress(widget.durationSec * 1000)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        Text(
          '发送日期分布${_dates.length > 90 ? '（最近 90 天）' : ''}',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        if (dates.isNotEmpty) ...[
          _Bars(
            values: dates.map((e) => e.value).toList(),
            color: color,
            labelOf: (i) => '${dates[i].key} · ${dates[i].value} 条',
          ),
          Text(
            '${dates.first.key} → ${dates.last.key}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 18),
        Text('发送时段分布（0–23 点）', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        _Bars(
          values: _hours,
          color: color,
          labelOf: (i) => '$i 点 · ${_hours[i]} 条',
        ),
        const SizedBox(height: 18),
        Text('弹幕类型', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          _modes.entries.map((e) => '${e.key} ${e.value}').join('  ·  '),
        ),
      ],
    );
  }
}

/// 简单柱状图，点击柱子显示数值
class _Bars extends StatelessWidget {
  const _Bars({
    required this.values,
    required this.color,
    required this.labelOf,
  });

  final List<int> values;
  final Color color;
  final String Function(int i) labelOf;

  @override
  Widget build(BuildContext context) {
    final max = values.fold<int>(0, math.max);
    return SizedBox(
      height: 110,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth / math.max(1, values.length);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final i = (d.localPosition.dx / w).floor().clamp(
                0,
                values.length - 1,
              ).toInt();
              SmartDialog.showToast(labelOf(i));
            },
            child: CustomPaint(
              size: Size(constraints.maxWidth, 110),
              painter: _BarsPainter(values, max, color),
            ),
          );
        },
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, this.max, this.color);

  final List<int> values;
  final int max;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || max == 0) return;
    final paint = Paint()..color = color;
    final w = size.width / values.length;
    final gap = w > 4 ? 1.0 : 0.0;
    for (var i = 0; i < values.length; i++) {
      final h = size.height * values[i] / max;
      canvas.drawRect(
        Rect.fromLTWH(i * w + gap / 2, size.height - h, w - gap, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values || old.max != max || old.color != color;
}
