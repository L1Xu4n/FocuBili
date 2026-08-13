import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/flutter_video_frame_capture.dart';

/// 验证 Windows 使用的 Flutter 画面取帧器不依赖播放器原生截图接口。
void main() {
  /// 挂载一个已绘制画面后应得到带标准文件头的非空 PNG 数据。
  testWidgets('Flutter 视频画面取帧生成 PNG', (WidgetTester tester) async {
    final FlutterVideoFrameCapture capture = FlutterVideoFrameCapture();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 80,
            height: 45,
            child: capture.wrap(const ColoredBox(color: Colors.blue)),
          ),
        ),
      ),
    );
    await tester.pump();

    final Uint8List? bytes = await tester.runAsync<Uint8List?>(
      () => capture.capturePngBytes(),
    );

    expect(bytes, isNotNull);
    expect(bytes, isNotEmpty);
    expect(
      bytes!.take(8),
      orderedEquals(const <int>[137, 80, 78, 71, 13, 10, 26, 10]),
    );
  });

  /// 画面在普通布局、横向工作台和全屏父树之间切换时应重新登记边界，不能触发 GlobalKey 重挂载断言。
  testWidgets('Flutter 视频画面跨父树切换后仍可安全取帧', (WidgetTester tester) async {
    final FlutterVideoFrameCapture capture = FlutterVideoFrameCapture();
    final List<Widget Function(Widget)> layouts = <Widget Function(Widget)>[
      (Widget child) => ColoredBox(
        color: Colors.black,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
      (Widget child) => ClipRect(
        child: Align(alignment: Alignment.centerRight, child: child),
      ),
      (Widget child) => DecoratedBox(
        decoration: const BoxDecoration(color: Colors.black),
        child: Center(child: child),
      ),
    ];

    for (int index = 0; index < layouts.length * 3; index += 1) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 80,
              height: 45,
              child: layouts[index % layouts.length](
                capture.wrap(
                  const SizedBox.expand(child: ColoredBox(color: Colors.blue)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final Uint8List? bytes = await tester.runAsync<Uint8List?>(
        () => capture.capturePngBytes(),
      );
      expect(bytes, isNotNull, reason: '第 $index 次布局切换后应保留当前取帧边界');
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(await capture.capturePngBytes(), isNull);
    expect(tester.takeException(), isNull);
  });

  /// 未挂载画面时必须安全返回空值，关联流程仍可继续保存视频信息。
  test('Flutter 视频画面未挂载时安全返回空值', () async {
    final FlutterVideoFrameCapture capture = FlutterVideoFrameCapture();

    expect(await capture.capturePngBytes(), isNull);
  });

  /// 非法像素倍率不进入 Flutter 渲染读取，避免产生无效图片或底层断言。
  test('Flutter 视频画面拒绝非法像素倍率', () async {
    final FlutterVideoFrameCapture capture = FlutterVideoFrameCapture();

    expect(await capture.capturePngBytes(pixelRatio: 0), isNull);
    expect(await capture.capturePngBytes(pixelRatio: double.nan), isNull);
  });
}
