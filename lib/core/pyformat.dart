/// 與 Python 相同的數字格式化。
///
/// 提示文字要和 Python 版（已驗證）逐字相同，所以四捨五入照 Python：
/// 依 double 的「精確二進位值」四捨五入，剛好一半時取偶數（round-half-even）。
/// Dart 內建的 toStringAsFixed 在剛好一半時會進位，結果可能差一位。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// double 的精確值：mantissa × 2^exponent（mantissa ≥ 0）；負號另外看 isNegative。
/// 用兩個 32 位元讀取（網頁版的 JavaScript 不支援 64 位元整數）。
(BigInt, int) _exact(double x) {
  final bytes = ByteData(8)..setFloat64(0, x.abs());
  final hi = bytes.getUint32(0);
  final lo = bytes.getUint32(4);
  final expBits = (hi >> 20) & 0x7ff;
  final frac = (BigInt.from(hi & 0xfffff) << 32) | BigInt.from(lo);
  if (expBits == 0) {
    return (frac, -1074); // 次正規數
  }
  return (frac | (BigInt.one << 52), expBits - 1075);
}

/// round(|x| × 10^d)（精確，剛好一半取偶數）。
BigInt _scaledRound(double x, int d) {
  final (m, e) = _exact(x);
  BigInt num = m;
  BigInt den = BigInt.one;
  if (d >= 0) {
    num *= BigInt.from(10).pow(d);
  } else {
    den *= BigInt.from(10).pow(-d);
  }
  if (e >= 0) {
    num <<= e;
  } else {
    den <<= -e;
  }
  final q = num ~/ den;
  final r = num - q * den;
  final twice = r * BigInt.two;
  if (twice > den || (twice == den && q.isOdd)) return q + BigInt.one;
  return q;
}

/// Python f"{x:.{d}f}"。
String fixed(double x, int d) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x > 0 ? 'inf' : '-inf';
  final q = _scaledRound(x, d).toString();
  final sign = x.isNegative ? '-' : '';
  if (d == 0) return '$sign$q';
  final padded = q.padLeft(d + 1, '0');
  final i = padded.length - d;
  return '$sign${padded.substring(0, i)}.${padded.substring(i)}';
}

/// Python f"{x:+.{d}f}"：正數也加「+」。
String signedFixed(double x, int d) {
  final s = fixed(x, d);
  return s.startsWith('-') ? s : '+$s';
}

/// Python round(x, d)（回傳 double）。
double pyRound(double x, int d) => double.parse(fixed(x, d));

/// Python f"{x:g}"：6 位有效數字、去掉多餘的 0；指數 < −4 或 ≥ 6 時用科學記號。
String g(double x) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x > 0 ? 'inf' : '-inf';
  final sign = x.isNegative ? '-' : '';
  if (x == 0) return '${sign}0';
  const p = 6;
  // 先估指數，再用精確四捨五入修正（進位可能讓位數多一位）
  var exp = (_log10(x.abs())).floor();
  var digits = _scaledRound(x, p - 1 - exp);
  if (digits.toString().length > p) {
    exp += 1;
    digits = _scaledRound(x, p - 1 - exp);
  } else if (digits.toString().length < p) {
    exp -= 1;
    digits = _scaledRound(x, p - 1 - exp);
  }
  if (exp >= -4 && exp < p) {
    final s = fixed(x.abs(), p - 1 - exp);
    return sign + _strip(s);
  }
  final ds = digits.toString();
  var mant = ds.length > 1 ? '${ds[0]}.${ds.substring(1)}' : ds;
  mant = _strip(mant);
  final es = exp.abs().toString().padLeft(2, '0');
  return '$sign${mant}e${exp < 0 ? '-' : '+'}$es';
}

/// 只用來估指數；估錯一位時 g() 會依位數修正。
double _log10(double v) => math.log(v) / math.ln10;

String _strip(String s) {
  if (!s.contains('.')) return s;
  s = s.replaceFirst(RegExp(r'0+$'), '');
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// Python 版 _num：f"{v:.2f}" 去掉多餘的 0（23.45、30.5、5）。
String numText(double v) => _strip(fixed(v, 2));

/// Python f"{x:.0%}"。
String percent0(double x) => '${fixed(x * 100, 0)}%';
