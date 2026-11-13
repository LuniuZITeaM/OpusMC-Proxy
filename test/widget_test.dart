import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_agent/main.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  for (final width in [320.0, 420.0, 800.0, 1366.0]) {
    testWidgets('Dashboard renders without overflow at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MyApp());
      expect(find.text('OpusMCAgent'), findsOneWidget);
      expect(find.text('等待登录'), findsOneWidget);
      expect(find.text('登录账户'), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
        'OpusMCAgent',
      );
      expect(
        tester.widget<TextField>(field('监听主机')).controller!.text,
        '127.0.0.1',
      );
      expect(tester.widget<TextField>(field('端口')).controller!.text, '25565');
      expect(tester.widget<TextField>(field('身份识别码')).obscureText, isTrue);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('运行日志'));
      await tester.pumpAndSettle();
      expect(find.textContaining('工作台已就绪'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('Login validates locally and supports hiding the identity code', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('登录账户'));
    await tester.tap(find.text('登录账户'));
    await tester.pumpAndSettle();
    expect(find.text('请输入身份识别码'), findsOneWidget);
    await tester.enterText(field('身份识别码'), 'test-only-code');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('显示识别码'));
    await tester.tap(find.byTooltip('显示识别码'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('身份识别码')).obscureText, isFalse);
    await tester.ensureVisible(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('身份识别码')).obscureText, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MyApp());
    expect(tester.widget<TextField>(field('身份识别码')).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Room tabs and manual code work in a narrow window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('我的房间'));
    await tester.tap(find.text('我的房间'));
    await tester.pumpAndSettle();
    expect(find.text('登录后查看你的世界'), findsOneWidget);
    await tester.tap(find.text('邀请码'));
    await tester.pumpAndSettle();
    expect(find.text('朋友的世界，一码直达'), findsOneWidget);
    await tester.enterText(field('目标房间码'), 'ab12');
    tester.testTextInput.hide();
    await tester.ensureVisible(find.text('启动本地代理'));
    await tester.tap(find.text('启动本地代理'));
    await tester.pumpAndSettle();
    expect(find.text('请先使用识别码登录当前上游服务'), findsOneWidget);
    expect(find.text('停止代理'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
