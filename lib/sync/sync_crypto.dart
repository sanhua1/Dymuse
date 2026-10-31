// 同步凭证的加密：口令 → PBKDF2-HMAC-SHA256 → AES-256-GCM。
// 只有凭证文件加密；红心、歌单等普通数据以明文 JSON 存放，便于排查。
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class SyncCryptoError implements Exception {
  const SyncCryptoError(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncCrypto {
  const SyncCrypto._(this.key);
  final Uint8List key;

  static const iterations = 120000;
  static const _checkText = 'dymuse-sync-v1';

  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _derive(List<Object> args) {
    final passphrase = args[0] as String;
    final salt = args[1] as Uint8List;
    final rounds = args[2] as int;
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, rounds, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  /// 口令派生密钥较慢，放到后台线程。
  static Future<SyncCrypto> derive(
    String passphrase,
    Uint8List salt, {
    int rounds = iterations,
  }) async => SyncCrypto._(
    await Isolate.run(() => _derive([passphrase, salt, rounds])),
  );

  /// 测试与已有密钥复用。
  factory SyncCrypto.fromKey(Uint8List key) = SyncCrypto._;

  Map<String, dynamic> encrypt(String plain) {
    final iv = randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final out = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return {'v': 1, 'iv': base64.encode(iv), 'ct': base64.encode(out)};
  }

  String decrypt(Map<String, dynamic> blob) {
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            128,
            base64.decode('${blob['iv']}'),
            Uint8List(0),
          ),
        );
      return utf8.decode(cipher.process(base64.decode('${blob['ct']}')));
    } catch (_) {
      throw const SyncCryptoError('同步密码不正确，或数据已损坏。');
    }
  }

  /// 写入清单的校验块；之后用它判断口令是否正确。
  Map<String, dynamic> checkBlock() => encrypt(_checkText);
  bool verify(Map<String, dynamic> block) {
    try {
      return decrypt(block) == _checkText;
    } on SyncCryptoError {
      return false;
    }
  }
}
