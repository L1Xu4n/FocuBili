import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/data_transfer_page.dart';
import 'package:focubili/services/data_transfer_file_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Runtime implements SettingsRuntimeAdapter {
  @override
  Future<Map<String, Object>> readSettings() async => {};
  @override
  Future<void> writeSettings(Map<String, Object?> values) async {}
}

// 单独的往返用例验证实际持久化。其他 UI 用例记录确认后的调用，避免
// SettingsTransferService 进程级写队列跨 Widget 测试的独立虚拟时钟。
class _RecordingSettings extends SettingsTransferService {
  final imports = <Map<String, Object>>[];
  @override
  Future<String> exportSettings() async =>
      '{"format":"focubili-settings","schemaVersion":1,"settings":{"appearance.theme_mode":"dark"}}';
  @override
  Future<void> importSettings(Map<String, Object> values) async {
    imports.add(values);
  }
}

class _FileSave extends DataTransferFileService {
  final records = <String, String>{};
  @override
  Future<bool> saveJson(String name, String content) async {
    records[name] = content;
    return true;
  }
}

class _Picker extends FilePickerPlatform {
  File? selection;
  int calls = 0;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    calls++;
    final selected = selection;
    return selected == null
        ? null
        : FilePickerResult([
            PlatformFile(
              name: 'test.json',
              size: selected.lengthSync(),
              path: selected.path,
            ),
          ]);
  }
}

Future<void> _advance(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
  await t.pump();
}

Future<void> _tap(WidgetTester t, String label) async {
  final item = find.text(label);
  await t.ensureVisible(item);
  await t.tap(item);
  await _advance(t);
}

void main() {
  late _FileSave files;
  late _Picker picker;
  late SettingsTransferService service;
  String? clipboard;
  var reads = 0, writes = 0;
  late Future<Object?> Function() read;
  late Future<void> Function(String) write;
  setUp(() {
    files = _FileSave();
    service = _RecordingSettings();
    final original = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    SharedPreferences.setMockInitialValues({
      'appearance.theme_mode': 'dark',
      'focubili_bilibili_cookie': 'synthetic-session-marker',
      'focubili_notes_v1': 'synthetic-note-marker',
    });
    reads = writes = 0;
    clipboard = null;
    read = () async => clipboard == null ? null : {'text': clipboard};
    write = (data) async {
      clipboard = data;
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        return read();
      }
      if (call.method == 'Clipboard.setData') {
        writes++;
        await write((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  });
  Future<void> page(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: DataTransferPage(settingsService: service, fileService: files),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('设置文件和复制文本完全相同，未带账号或学习资料；回导只在确认时写入', (t) async {
    service = SettingsTransferService(runtimeAdapter: _Runtime());
    await page(t);
    await _tap(t, '导出设置');
    await _tap(t, '保存为文件');
    final file = files.records['FocuBili-settings.json'];
    expect(file, await service.exportSettings());
    expect(writes, 0);
    await _tap(t, '导出设置');
    await _tap(t, '复制到剪贴板');
    expect(clipboard, file);
    expect(writes, 1);
    expect(reads, 0);
    expect(clipboard, isNot(contains('synthetic')));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appearance.theme_mode', 'light');
    for (final confirm in [false, true]) {
      await _tap(t, '导入设置');
      await _tap(t, '从文本导入');
      expect(reads, confirm ? 1 : 0);
      await _tap(t, '从剪贴板粘贴');
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        file,
      );
      await _tap(t, '下一步');
      expect(find.textContaining('1 项设置'), findsOneWidget);
      expect(prefs.getString('appearance.theme_mode'), 'light');
      await _tap(t, confirm ? '确认导入' : '取消');
    }
    expect(prefs.getString('appearance.theme_mode'), 'dark');
    expect(
      prefs.getString('focubili_bilibili_cookie'),
      'synthetic-session-marker',
    );
    expect(prefs.getString('focubili_notes_v1'), 'synthetic-note-marker');
  });

  testWidgets('设置导入保留实际文件读取和确认；原登录导入导出没有文本方式', (t) async {
    final directory = Directory.systemTemp.createTempSync(
      'settings-transfer-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/data.json');
    picker.selection = file;
    file.writeAsStringSync(
      jsonEncode({
        'format': 'focubili-settings',
        'schemaVersion': 1,
        'settings': {'appearance.theme_mode': 'light'},
      }),
    );
    await page(t);
    await _tap(t, '导入设置');
    await _tap(t, '从文件导入');
    Future<void> waitFor(String text) async {
      for (var i = 0; i < 100 && find.text(text).evaluate().isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await _advance(t);
      }
      expect(find.text(text), findsOneWidget);
    }

    await waitFor('确认导入');
    await _tap(t, '确认导入');
    expect((service as _RecordingSettings).imports.single, {
      'appearance.theme_mode': 'light',
    });
    expect(picker.calls, 1);
    await _tap(t, '导出登录信息');
    expect(find.textContaining('明文 Cookie'), findsOneWidget);
    expect(find.text('复制到剪贴板'), findsNothing);
    await _tap(t, '取消');
    file.writeAsStringSync(
      jsonEncode({
        'format': 'focubili-login',
        'schemaVersion': 1,
        'cookie': 'synthetic-invalid-for-real-login',
      }),
    );
    await _tap(t, '导入登录信息');
    await waitFor('验证并导入');
    expect(picker.calls, 2);
    expect(find.text('从文本导入'), findsNothing);
    await _tap(t, '取消');
    expect([reads, writes], [0, 0]);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'focubili_bilibili_cookie',
      ),
      'synthetic-session-marker',
    );
  });

  testWidgets('手动文本、错误 JSON、未知敏感设置及登录文件不混用；失败保留草稿', (t) async {
    await page(t);
    await _tap(t, '导入设置');
    await _tap(t, '从文本导入');
    final field = find.byType(TextField);
    for (final source in [
      '{bad',
      '{"format":"focubili-login","schemaVersion":1,"cookie":"synthetic"}',
      '{"format":"focubili-settings","schemaVersion":1,"settings":{"appearance.theme_mode":"light","focubili_bilibili_cookie":"not-allowed"}}',
    ]) {
      await t.enterText(field, source);
      await _tap(t, '下一步');
      expect(find.textContaining('不是有效的设置备份'), findsOneWidget);
      expect(t.widget<TextField>(field).controller!.text, source);
      expect(find.text('确认导入'), findsNothing);
    }
    await t.enterText(
      field,
      '{"format":"focubili-settings","schemaVersion":1,"settings":{"appearance.theme_mode":"light"}}',
    );
    await _tap(t, '下一步');
    await _tap(t, '确认导入');
    expect((service as _RecordingSettings).imports.single, {
      'appearance.theme_mode': 'light',
    });
    expect(writes + reads, 0);
  });

  testWidgets('剪贴板写入返回才报告成功；被系统拒绝不误报；取消选择不读写', (t) async {
    final pending = Completer<void>();
    write = (_) => pending.future;
    await page(t);
    await _tap(t, '导出设置');
    await _tap(t, '取消');
    expect(writes + reads, 0);
    await _tap(t, '导出设置');
    await _tap(t, '复制到剪贴板');
    expect(writes, 1);
    expect(find.textContaining('已复制到剪贴板'), findsNothing);
    expect(
      t.widget<ListTile>(find.widgetWithText(ListTile, '导出设置')).onTap,
      isNull,
    );
    pending.complete();
    await _advance(t);
    expect(find.textContaining('已复制到剪贴板'), findsOneWidget);
    ScaffoldMessenger.of(
      t.element(find.byType(DataTransferPage)),
    ).removeCurrentSnackBar();
    await _advance(t);
    write = (_) async => throw PlatformException(code: 'blocked');
    await _tap(t, '导出设置');
    await _tap(t, '复制到剪贴板');
    expect(find.textContaining('无法写入剪贴板'), findsOneWidget);
    expect(find.textContaining('已复制到剪贴板'), findsNothing);
  });

  testWidgets('空剪贴板、过大或读取失败均不覆盖草稿；取消后迟到回复不影响页面', (t) async {
    await page(t);
    await _tap(t, '导入设置');
    await _tap(t, '从文本导入');
    final field = find.byType(TextField);
    await t.enterText(field, '草稿');
    await _tap(t, '从剪贴板粘贴');
    expect(find.textContaining('剪贴板没有文本'), findsOneWidget);
    clipboard = '界' * (SettingsTransferService.maximumBytes ~/ 3 + 1);
    await _tap(t, '从剪贴板粘贴');
    expect(find.textContaining('不能超过 2 MB'), findsOneWidget);
    read = () async => throw PlatformException(code: 'denied');
    await _tap(t, '从剪贴板粘贴');
    expect(find.textContaining('无法读取剪贴板'), findsOneWidget);
    expect(t.widget<TextField>(field).controller!.text, '草稿');
    final pending = Completer<Object?>();
    read = () => pending.future;
    await _tap(t, '从剪贴板粘贴');
    await _tap(t, '取消');
    pending.complete({'text': await service.exportSettings()});
    await _advance(t);
    expect(find.text('确认导入'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'appearance.theme_mode',
      ),
      'dark',
    );
    expect(t.takeException(), isNull);
  });
}
