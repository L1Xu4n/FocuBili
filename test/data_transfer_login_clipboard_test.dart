import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/data_transfer_page.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/data_transfer_file_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixture = 'SESSDATA=synthetic-test-marker';

class _Save extends DataTransferFileService {
  final files = <String, String>{};
  @override
  Future<bool> saveJson(String name, String content) async {
    files[name] = content;
    return true;
  }
}

class _Store implements BilibiliCookieStore {
  String session = 'SESSDATA=previous-test-account';
  int reads = 0, writes = 0;
  @override
  Future<String> readCookies() async {
    reads++;
    return session;
  }

  @override
  Future<void> replaceCookies(String value) async {
    writes++;
    session = value;
  }

  @override
  Future<void> clearBilibiliCookies() async {
    session = '';
  }
}

class _Nav implements BilibiliAuthApi {
  var allowed = false;
  int calls = 0;
  @override
  Future<BilibiliNavResponse> requestNavigation(String _) async {
    calls++;
    return BilibiliNavResponse(
      statusCode: 200,
      body: allowed
          ? '{"code":0,"data":{"isLogin":true,"mid":7,"uname":"synthetic"}}'
          : '{"code":-101}',
    );
  }
}

class _ControlledAuth extends BilibiliAuthService {
  _ControlledAuth() : super(cookieStore: _Store(), api: _Nav());
  var reads = 0;
  Completer<String>? pending;
  @override
  Future<String> readCookieForExport() async {
    reads++;
    return await (pending?.future ?? Future.value(_fixture));
  }
}

Future<void> _frame(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
  await t.pump();
}

Future<void> _tap(WidgetTester t, String label) async {
  final f = find.text(label);
  await t.ensureVisible(f);
  await t.tap(f);
  await _frame(t);
}

void main() {
  final backup = jsonEncode({
    'format': 'focubili-login',
    'schemaVersion': 1,
    'cookie': _fixture,
  });
  late _Save files;
  late _ControlledAuth controlled;
  late Future<Object?> Function() getClipboard;
  late Future<void> Function(String) setClipboard;
  var reads = 0, writes = 0;
  String? copied;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    files = _Save();
    controlled = _ControlledAuth();
    reads = writes = 0;
    copied = null;
    getClipboard = () async => {'text': backup};
    setClipboard = (s) async {
      copied = s;
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        return getClipboard();
      }
      if (call.method == 'Clipboard.setData') {
        writes++;
        await setClipboard((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  });
  Future<void> page(WidgetTester t, [BilibiliAuthService? service]) async {
    await t.pumpWidget(
      MaterialApp(
        home: DataTransferPage(
          fileService: files,
          authService: service ?? controlled,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('明确确认目的地后才能读取会话；剪贴板与原文件严格同格式', (t) async {
    await page(t);
    await _tap(t, '导出登录信息');
    await _tap(t, '复制到剪贴板');
    expect(find.textContaining('云同步'), findsOneWidget);
    expect(controlled.reads, 0);
    expect(reads + writes, 0);
    await _tap(t, '取消');
    expect(controlled.reads, 0);
    await _tap(t, '导出登录信息');
    await _tap(t, '保存为文件');
    expect(find.textContaining('文件包含可用于登录账号的明文 Cookie'), findsOneWidget);
    await _tap(t, '我已了解，导出');
    expect(files.files['FocuBili-login-private.json'], backup);
    expect(writes, 0);
    expect(find.text('已导出文件'), findsOneWidget);
    final pending = Completer<void>();
    setClipboard = (s) async {
      await pending.future;
      copied = s;
    };
    await _tap(t, '导出登录信息');
    await _tap(t, '复制到剪贴板');
    await _tap(t, '我已了解，复制');
    expect(writes, 1);
    expect(copied, isNull);
    expect(find.text('已复制到剪贴板'), findsNothing);
    pending.complete();
    await _frame(t);
    expect(copied, files.files['FocuBili-login-private.json']);
    expect(find.text('已复制到剪贴板'), findsOneWidget);
    expect(controlled.reads, 2);
    expect(reads, 0);
    expect(find.textContaining(_fixture), findsNothing);
  });

  testWidgets('剪贴板拒绝不泄漏异常内容也不报告成功，没选粘贴不主动读取', (t) async {
    await page(t);
    getClipboard = () async =>
        throw PlatformException(code: 'denied', message: _fixture);
    setClipboard = (_) async =>
        throw PlatformException(code: 'denied', message: _fixture);
    await _tap(t, '导入登录信息');
    await _tap(t, '取消');
    expect(reads, 0);
    await _tap(t, '导入登录信息');
    await _tap(t, '从剪贴板粘贴');
    expect(reads, 1);
    expect(find.textContaining('无法读取剪贴板'), findsOneWidget);
    expect(find.textContaining(_fixture), findsNothing);
    ScaffoldMessenger.of(
      t.element(find.byType(DataTransferPage)),
    ).removeCurrentSnackBar();
    await _frame(t);
    await _tap(t, '导出登录信息');
    await _tap(t, '复制到剪贴板');
    await _tap(t, '我已了解，复制');
    expect(find.textContaining('无法写入剪贴板'), findsOneWidget);
    expect(find.text('已复制到剪贴板'), findsNothing);
    expect(find.textContaining(_fixture), findsNothing);
  });

  testWidgets('空、过大、错误包或设置备份不验证，不显示明文控件', (t) async {
    final store = _Store(), nav = _Nav();
    await page(t, BilibiliAuthService(cookieStore: store, api: nav));
    for (final bad in [
      null,
      '{bad',
      '{"format":"focubili-settings","schemaVersion":1,"settings":{}}',
      jsonEncode({
        'format': 'focubili-login',
        'schemaVersion': 1,
        'cookie': 'a' * 65537,
      }),
      '界' * (2 * 1024 * 1024 ~/ 3 + 1),
    ]) {
      getClipboard = () async => bad == null ? null : {'text': bad};
      await _tap(t, '导入登录信息');
      await _tap(t, '从剪贴板粘贴');
      expect(find.text('验证并导入'), findsNothing);
      expect(find.byType(EditableText), findsNothing);
    }
    expect(nav.calls, 0);
    expect(store.writes, 0);
    expect(writes, 0);
  });

  testWidgets('页面退出后迟到的会话快照不再写剪贴板', (t) async {
    controlled.pending = Completer<String>();
    await page(t);
    await _tap(t, '导出登录信息');
    await _tap(t, '复制到剪贴板');
    await _tap(t, '我已了解，复制');
    expect(controlled.reads, 1);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await _frame(t);
    controlled.pending!.complete(_fixture);
    await _frame(t);
    expect(writes, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('读取剪贴板期间退到后台，迟到内容不会开始导入', (t) async {
    final store = _Store(), nav = _Nav();
    await page(t, BilibiliAuthService(cookieStore: store, api: nav));
    final pending = Completer<Object?>();
    getClipboard = () => pending.future;
    await _tap(t, '导入登录信息');
    expect(reads, 0);
    await _tap(t, '从剪贴板粘贴');
    expect(reads, 1);
    try {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      pending.complete({'text': backup});
      await _frame(t);
    } finally {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    await _frame(t);
    expect(find.text('验证并导入'), findsNothing);
    expect(nav.calls, 0);
    expect(store.writes, 0);
  });

  testWidgets('取消不调用验证；过期保留旧账号，验证通过才替换合成存储', (t) async {
    final store = _Store(), nav = _Nav();
    final service = BilibiliAuthService(cookieStore: store, api: nav);
    await page(t, service);
    for (final step in ['取消', '验证并导入', '验证并导入']) {
      await _tap(t, '导入登录信息');
      expect(find.byType(EditableText), findsNothing);
      await _tap(t, '从剪贴板粘贴');
      expect(find.textContaining('连接 B 站验证'), findsOneWidget);
      expect(find.textContaining(_fixture), findsNothing);
      final before = nav.calls;
      await _tap(t, step);
      expect(nav.calls, before + (step == '取消' ? 0 : 1));
      if (!nav.allowed) {
        expect(store.writes, 0);
        expect(store.session, 'SESSDATA=previous-test-account');
      }
      if (step == '验证并导入') nav.allowed = true;
    }
    expect(store.writes, 1);
    expect(store.session, _fixture);
    expect(writes, 0);
    expect(t.takeException(), isNull);
  });
}
