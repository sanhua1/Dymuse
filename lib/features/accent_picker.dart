import 'package:flutter/cupertino.dart';
import '../design_system/tokens.dart';

/// 手动取色：色相、饱和度、明度三条滑杆加 #RRGGBB 输入，拖动时主题色实时变化；
/// 点“取消”恢复打开前的颜色。
class AccentPickerSheet extends StatefulWidget {
  const AccentPickerSheet({super.key, required this.appearance});
  final Appearance appearance;
  @override
  State<AccentPickerSheet> createState() => _AccentPickerSheetState();
}

class _AccentPickerSheetState extends State<AccentPickerSheet> {
  late final String before = widget.appearance.accentValue;
  late HSVColor hsv = HSVColor.fromColor(
    widget.appearance.custom ?? widget.appearance.accentLight,
  );
  late final hex = TextEditingController(text: _hex(hsv.toColor()));

  static String _hex(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  void set(HSVColor next, {bool fromText = false}) {
    setState(() => hsv = next);
    if (!fromText) hex.text = _hex(next.toColor());
    widget.appearance.update(custom: next.toColor());
  }

  void typed(String text) {
    final clean = text.replaceAll('#', '');
    if (clean.length != 6) return;
    final value = int.tryParse(clean, radix: 16);
    if (value != null) {
      set(HSVColor.fromColor(Color(0xFF000000 | value)), fromText: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = hsv.toColor();
    return CupertinoPopupSurface(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      widget.appearance.applyAccent(before);
                      Navigator.pop(context);
                    },
                    child: const Text('取消'),
                  ),
                  const Expanded(
                    child: Text(
                      '自定义主题色',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      '完成',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(height: 18),
              _Bar(
                label: '色相',
                value: hsv.hue / 360,
                colors: [
                  for (var h = 0; h <= 360; h += 60)
                    HSVColor.fromAHSV(1, h % 361.0, 1, 1).toColor(),
                ],
                onChanged: (v) => set(hsv.withHue((v * 360).clamp(0, 359.9))),
              ),
              _Bar(
                label: '饱和度',
                value: hsv.saturation,
                colors: [
                  hsv.withSaturation(0).toColor(),
                  hsv.withSaturation(1).toColor(),
                ],
                onChanged: (v) => set(hsv.withSaturation(v)),
              ),
              _Bar(
                label: '明度',
                value: hsv.value,
                colors: [
                  hsv.withValue(0).toColor(),
                  hsv.withValue(1).toColor(),
                ],
                onChanged: (v) => set(hsv.withValue(v)),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Text('颜色值', style: DymuseTokens.body),
                  const SizedBox(width: 12),
                  Expanded(
                    child: CupertinoTextField(
                      controller: hex,
                      prefix: const Padding(
                        padding: EdgeInsets.only(left: 10),
                        child: Text('#'),
                      ),
                      maxLength: 7,
                      onChanged: typed,
                      padding: const EdgeInsets.all(10),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '浅色与深色模式下会自动调整明暗，保证文字清晰。',
                style: DymuseTokens.caption.copyWith(
                  color: DymuseTokens.secondary(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });
  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        SizedBox(width: 56, child: Text(label, style: DymuseTokens.body)),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              void at(double dx) =>
                  onChanged((dx / box.maxWidth).clamp(0.0, 1.0));
              return Semantics(
                slider: true,
                label: label,
                value: '${(value * 100).round()}%',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (d) => at(d.localPosition.dx),
                  onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
                  onTapDown: (d) => at(d.localPosition.dx),
                  child: SizedBox(
                    height: 32,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 14,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(7),
                            gradient: LinearGradient(colors: colors),
                          ),
                        ),
                        Positioned(
                          left: (box.maxWidth - 24) * value,
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFFFFFFF),
                              border: Border.all(
                                color: const Color(0x33000000),
                                width: 1,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
