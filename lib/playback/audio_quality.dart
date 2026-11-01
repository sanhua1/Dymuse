import '../design_system/tokens.dart';

/// 全局音质：网易云的五个常用档位，从低到高排列。
/// [detailKey] 是 `/song/music/detail` 里该档位对应的字段，值为 null 表示这首歌没有该档位。
enum AudioQuality {
  standard('standard', 'l', '标准', '128K'),
  higher('higher', 'm', '较高', '192K'),
  exhigh('exhigh', 'h', '极高', '320K'),
  lossless('lossless', 'sq', '无损', 'FLAC'),
  hires('hires', 'hr', 'Hi-Res', 'FLAC 高解析度');

  const AudioQuality(this.level, this.detailKey, this.label, this.hint);
  final String level, detailKey, label, hint;

  /// 没有设置过时的默认音质：手机省流量，桌面尽量用最高音质。
  /// 音质是每台设备自己的设置，不通过 WebDAV 同步。
  static AudioQuality get fallback =>
      DymuseTokens.mobile ? AudioQuality.standard : AudioQuality.hires;

  static AudioQuality fromName(String? name) => AudioQuality.values.firstWhere(
    (quality) => quality.name == name,
    orElse: () => fallback,
  );

  /// 按歌曲实际提供的档位匹配：取不高于本档的最高可用档位。
  /// 例如选了 Hi-Res 而这首歌没有，就依次降到无损、极高……；
  /// 档位信息取不到时直接按本档请求，由网易云按账号权限降级。
  String match(Map<String, dynamic>? detail) {
    final available = detail?['data'];
    if (available is! Map) return level;
    for (var i = index; i >= 0; i--) {
      if (available[values[i].detailKey] is Map) return values[i].level;
    }
    return AudioQuality.standard.level;
  }
}
