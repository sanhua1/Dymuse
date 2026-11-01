import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// 与 [CupertinoSheetRoute] 相同的 iOS 页面 Sheet；被盖住的上一页沿用系统的圆角裁剪，
/// 尖角问题由 [sheetCovering]（收起顶部模糊带）解决，不再用离屏层裁剪（又慢又会让玻璃闪一下）。
class DymuseSheetRoute<T> extends CupertinoSheetRoute<T> {
  DymuseSheetRoute({required super.builder});

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _coveredPage;

  static const _scale = 1.0 - 0.0835;

  static Widget _coveredPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (CupertinoSheetRoute.hasParentSheet(context)) {
      return CupertinoSheetTransition.delegateTransition(
        context,
        animation,
        secondaryAnimation,
        allowSnapshotting,
        child,
      );
    }
    final linear = Navigator.of(context).userGestureInProgress;
    final curved = CurvedAnimation(
      curve: linear ? Curves.linear : Curves.linearToEaseOut,
      reverseCurve: linear ? Curves.linear : Curves.easeInToLinear,
      parent: secondaryAnimation,
    );
    final deviceCorner =
        (MediaQuery.maybeViewPaddingOf(context)?.top ?? 0) * .9;
    final radius = curved.drive(
      Tween<BorderRadiusGeometry>(
        begin: BorderRadius.vertical(
          top: Radius.circular(deviceCorner > 20 ? deviceCorner : 0),
        ),
        end: BorderRadius.circular(12),
      ),
    );
    final dim = curved.drive(Tween<double>(begin: 0, end: .10));
    final slide = curved.drive(
      Tween<Offset>(begin: Offset.zero, end: const Offset(0, .07)),
    );
    final scale = curved.drive(Tween<double>(begin: 1, end: _scale));
    curved.dispose();
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final covered = child != null && !secondaryAnimation.isDismissed
        ? Stack(
            children: [
              child,
              FadeTransition(
                opacity: dim,
                child: ColoredBox(
                  color: dark
                      ? const Color(0xFFC8C8C8)
                      : const Color(0xFF000000),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          )
        : child;
    return Stack(
      children: [
        AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarBrightness: Brightness.dark,
            statusBarIconBrightness: Brightness.light,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .08,
            width: double.infinity,
          ),
        ),
        SlideTransition(
          position: slide,
          child: ScaleTransition(
            scale: scale,
            filterQuality: FilterQuality.medium,
            alignment: Alignment.topCenter,
            child: AnimatedBuilder(
              animation: radius,
              child: covered,
              builder: (context, child) => ClipRSuperellipse(
                borderRadius: secondaryAnimation.isDismissed
                    ? BorderRadius.zero
                    : radius.value,
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 页面 Sheet 正盖在主页上时为 true。主页顶部的渐进模糊带是着色器滤镜，
/// 不服从外层的圆角裁剪，被盖住缩小后会在圆角外露出尖角；盖住期间先把它收起来。
final ValueNotifier<bool> sheetCovering = ValueNotifier(false);

/// 打开页面 Sheet（设置、播放页等）；返回时 Sheet 已完全收起。
Future<T?> showDymuseSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  sheetCovering.value = true;
  try {
    return await Navigator.of(
      context,
      rootNavigator: true,
    ).push<T>(DymuseSheetRoute<T>(builder: builder));
  } finally {
    sheetCovering.value = false;
  }
}
