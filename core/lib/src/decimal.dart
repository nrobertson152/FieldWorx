// SPDX-License-Identifier: GPL-3.0-or-later
// Exact decimals for measurements and quantities. The protocol never uses floating point: values travel as text
// like "12.5" or "-0.05" and are compared exactly (spec/vectors/decimals.json).

final RegExp reDecimal = RegExp(r'^-?(0|[1-9]\d{0,14})(\.\d{1,9})?$');

bool isDecimal(Object? s) => s is String && reDecimal.hasMatch(s);

/// The value scaled by 10^9, so that comparisons are exact.
BigInt _scaled(String s) {
  if (!isDecimal(s)) throw FormatException('not a plain decimal: $s');
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final dot = body.indexOf('.');
  final intPart = dot < 0 ? body : body.substring(0, dot);
  final frac = dot < 0 ? '' : body.substring(dot + 1);
  final v = BigInt.parse(intPart + frac.padRight(9, '0'));
  return neg ? -v : v;
}

/// -1, 0 or 1. "-0" equals "0"; "1.50" equals "1.5".
int compareDecimal(String a, String b) => _scaled(a).compareTo(_scaled(b)).sign;

/// Parses user input into a plain decimal ("12,5" is accepted as "12.5"; "+3" as "3"). Returns null if it isn't one.
String? normalizeDecimalInput(String input) {
  var s = input.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (s.startsWith('+')) s = s.substring(1);
  if (s.startsWith('.')) s = '0$s';
  if (s.startsWith('-.')) s = '-0${s.substring(1)}';
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  // Strip leading zeros the grammar doesn't allow ("007" -> "7"), keeping one before a point.
  final neg = s.startsWith('-');
  var body = neg ? s.substring(1) : s;
  while (body.length > 1 && body.startsWith('0') && body[1] != '.') {
    body = body.substring(1);
  }
  s = (neg ? '-' : '') + body;
  return isDecimal(s) ? s : null;
}
