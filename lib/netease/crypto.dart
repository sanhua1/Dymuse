// 网易云请求加密（移植自 api-enhanced/util/crypto.js 的 weapi / eapi / linuxapi）。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:pointycastle/export.dart';

const _iv = '0102030405060708';
const _presetKey = '0CoJUm6Qyw8W8jud';
const _linuxapiKey = 'rFgB&h#%2?^eDg:Q';
const _eapiKey = 'e82ckenh8dichen8';
const _base62 =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
// 与 crypto.js 中 publicKey 相同的 RSA 1024 公钥（模数 / 指数）。
final _modulus = BigInt.parse(
  'E0B509F6259DF8642DBC35662901477DF22677EC152B5FF68ACE615BB7B725152B3AB17A'
  '876AEA8A5AA76D2E417629EC4EE341F56135FCCF695280104E0312ECBDA92557C9387011'
  '4AF6C9D05C4F7F0C3685B7A46BEE255932575CCE10B424D813CFE4875D3E82047B97DDEF'
  '52741D546B8E289DC6935B3ECE0462DB0A22B8E7',
  radix: 16,
);
final _exponent = BigInt.from(65537);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

String _hex(List<int> data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _aes(Uint8List data, String key, {String? iv, bool encrypt = true}) {
  final BlockCipher mode = iv == null
      ? ECBBlockCipher(AESEngine())
      : CBCBlockCipher(AESEngine());
  final params = iv == null
      ? KeyParameter(_bytes(key))
      : ParametersWithIV(KeyParameter(_bytes(key)), _bytes(iv));
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), mode)
    ..init(encrypt, PaddedBlockCipherParameters(params, null));
  return cipher.process(data);
}

/// 无填充 RSA：明文按大端整数直接取模幂，输出补足 256 位十六进制。
String _rsa(String text) {
  final value = BigInt.parse(_hex(_bytes(text)), radix: 16);
  return value.modPow(_exponent, _modulus).toRadixString(16).padLeft(256, '0');
}

String randomKey([Random? random]) {
  final r = random ?? Random.secure();
  // crypto.js 用 Math.round(random * 61)，字符集只取前 62 个，这里等价取均匀值。
  return List.generate(16, (_) => _base62[r.nextInt(62)]).join();
}

Map<String, String> weapi(Map<String, Object?> object, {String? secretKey}) {
  final text = jsonEncode(object);
  final key = secretKey ?? randomKey();
  final first = base64.encode(_aes(_bytes(text), _presetKey, iv: _iv));
  final params = base64.encode(_aes(_bytes(first), key, iv: _iv));
  return {'params': params, 'encSecKey': _rsa(key.split('').reversed.join())};
}

Map<String, String> linuxapi(Map<String, Object?> object) => {
  'eparams': _hex(_aes(_bytes(jsonEncode(object)), _linuxapiKey)).toUpperCase(),
};

Map<String, String> eapi(String url, Map<String, Object?> object) {
  final text = jsonEncode(object);
  final digest = hash.md5.convert(
    utf8.encode('nobody${url}use${text}md5forencrypt'),
  );
  final data = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
  return {'params': _hex(_aes(_bytes(data), _eapiKey)).toUpperCase()};
}

/// 解开 eapi 请求参数，测试时用来核对。
String eapiDecrypt(String hex) {
  final data = Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
  return utf8.decode(_aes(data, _eapiKey, encrypt: false));
}

/// 解开 weapi 的 params（需已知随机密钥），测试时用来核对。
String weapiDecrypt(String params, String secretKey) {
  final first = _aes(base64.decode(params), secretKey, iv: _iv, encrypt: false);
  return utf8.decode(
    _aes(
      base64.decode(utf8.decode(first)),
      _presetKey,
      iv: _iv,
      encrypt: false,
    ),
  );
}
