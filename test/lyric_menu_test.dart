import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dymuse/playback/lyric_layers.dart';
import 'package:dymuse/playback/player_view.dart';

void main() {
  testWidgets('有翻译时“译”菜单按钮出现在按钮行里', (tester) async {
    LyricStore.instance.show(
      LyricBundle.fromResponse({
        'lrc': {'lyric': '[00:01.00]a'},
        'tlyric': {'lyric': '[00:01.00]甲'},
      }, parseLrc),
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(CupertinoIcons.list_bullet),
              LyricLayerMenu(
                builder: (context, open, active) => Row(
                  children: [
                    const SizedBox(width: 48),
                    GestureDetector(
                      onTap: open,
                      child: const Icon(CupertinoIcons.globe),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(CupertinoIcons.globe), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
