import 'dart:typed_data';

/// 弹幕 midHash 反查 UID
///
/// midHash = crc32(uid 十进制字符串) 的 16 进制（不补零）。
/// 原理：CRC32 的最后 4 个字节可由前缀状态唯一反推，
/// 因此只需枚举 (位数 - 4) 位前缀，再校验反推出的 4 字节是否为数字。
/// 默认最多枚举到 11 位 UID（约 1000 万次，在 isolate 中执行）。
/// 16 位新 UID 无法暴力反查。
abstract final class DmMidHash {
  static final Uint32List _table = () {
    final t = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (c >>> 1) ^ 0xEDB88320 : c >>> 1;
      }
      t[i] = c;
    }
    return t;
  }();

  static int crc32(String s) {
    final t = _table;
    var c = 0xFFFFFFFF;
    for (final b in s.codeUnits) {
      c = t[(c ^ b) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String hashOf(int mid) => crc32(mid.toString()).toRadixString(16);

  /// 参数为 [hash, maxDigits]，便于 compute 调用
  static List<int> crackArgs(List<Object> args) =>
      crack(args[0] as String, maxDigits: args[1] as int);

  static List<int> crack(String hash, {int maxDigits = 11}) {
    final h = int.tryParse(hash, radix: 16);
    if (h == null) return const [];
    final t = _table;
    final top = List<int>.filled(256, -1);
    for (var i = 0; i < 256; i++) {
      top[t[i] >>> 24] = i;
    }
    // 反推最后 4 步使用的表索引
    final idx = List<int>.filled(4, 0);
    var s = (h ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    for (var k = 3; k >= 0; k--) {
      final i = top[s >>> 24];
      idx[k] = i;
      s = ((s ^ t[i]) << 8) & 0xFFFFFFFF;
    }

    final res = <int>[];
    // 1~4 位直接枚举
    for (var m = 0; m < 10000; m++) {
      if (crc32(m.toString()) == h) res.add(m);
    }
    for (var n = 5; n <= maxDigits; n++) {
      var lo = 1;
      for (var i = 0; i < n - 5; i++) {
        lo *= 10;
      }
      final hi = lo * 10;
      for (var p = lo; p < hi; p++) {
        // 前缀状态
        var c = 0xFFFFFFFF;
        for (final b in p.toString().codeUnits) {
          c = t[(c ^ b) & 0xFF] ^ (c >>> 8);
        }
        var out = 0;
        var ok = true;
        for (var k = 0; k < 4; k++) {
          final b = (c ^ idx[k]) & 0xFF;
          if (b < 48 || b > 57) {
            ok = false;
            break;
          }
          out = out * 10 + b - 48;
          c = t[idx[k]] ^ (c >>> 8);
        }
        if (ok) res.add(p * 10000 + out);
      }
    }
    return res;
  }
}
