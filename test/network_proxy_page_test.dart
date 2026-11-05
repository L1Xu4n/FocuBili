import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/network_proxy_page.dart';
import 'package:focubili/models/network_proxy_settings.dart';
import 'package:focubili/services/network_proxy_service.dart';

class _PageService extends NetworkProxyService {
  NetworkProxySettings stored = const NetworkProxySettings();
  final saves = <NetworkProxySettings>[];
  Completer<void>? pendingSave;
  Completer<NetworkProxySettings>? pendingLoad;
  bool failLoad = false;
  bool failSave = false;

  @override
  Future<NetworkProxySettings> load() async {
    if (failLoad) throw const FormatException('Unreadable settings');
    return pendingLoad == null ? stored : pendingLoad!.future;
  }

  @override
  Future<void> save(NetworkProxySettings settings) async {
    saves.add(settings);
    if (pendingSave != null) await pendingSave!.future;
    if (failSave) throw StateError('Storage failed');
    stored = settings;
  }
}

const _modeKey = Key('network-proxy-mode');
const _hostKey = Key('network-proxy-host');
const _portKey = Key('network-proxy-port');
const _saveKey = Key('save-network-proxy');

Future<void> _open(WidgetTester tester, _PageService service) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NetworkProxyPage(service: service),
              ),
            ),
            child: const Text('Open proxy settings'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open proxy settings'));
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.byKey(_modeKey));
  await tester.tap(find.byKey(_modeKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(_saveKey),
    200,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(find.byKey(_saveKey));
  await tester.tap(find.byKey(_saveKey));
  await tester.pump();
}

void main() {
  testWidgets('default is system and no setting is saved until Save', (
    tester,
  ) async {
    final service = _PageService();
    await _open(tester, service);
    expect(find.text('跟随系统（默认）'), findsOneWidget);
    expect(find.byKey(_hostKey), findsNothing);
    expect(service.saves, isEmpty);
    await _save(tester);
    expect(service.saves.single.mode, NetworkProxyMode.system);
    expect(find.text('已保存，完全退出并重新启动应用后生效。'), findsOneWidget);
  });

  testWidgets('invalid host and port do not save', (tester) async {
    final service = _PageService();
    await _open(tester, service);
    await _select(tester, '手动 HTTP 代理');
    await tester.enterText(
      find.byKey(_hostKey),
      'http://user:secret@proxy.local',
    );
    await tester.enterText(find.byKey(_portKey), '65536');
    await _save(tester);
    expect(service.saves, isEmpty);
    expect(find.text('只填写主机名或 IP，不包含协议、路径或账号密码'), findsOneWidget);
    expect(find.text('端口须为 1–65535 的整数'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual save trims input and reports restart requirement', (
    tester,
  ) async {
    final service = _PageService();
    await _open(tester, service);
    await _select(tester, '手动 HTTP 代理');
    await tester.enterText(find.byKey(_hostKey), ' [::1] ');
    await tester.enterText(find.byKey(_portKey), ' 8080 ');
    await _save(tester);
    expect(service.saves.single.mode, NetworkProxyMode.manual);
    expect(service.saves.single.host, '[::1]');
    expect(service.saves.single.port, 8080);
    expect(find.text('已保存，完全退出并重新启动应用后生效。'), findsOneWidget);
  });

  testWidgets('switching away from manual clears obsolete host and port', (
    tester,
  ) async {
    final service = _PageService()
      ..stored = const NetworkProxySettings(
        mode: NetworkProxyMode.manual,
        host: 'proxy.local',
        port: 3128,
      );
    await _open(tester, service);
    await _select(tester, '直接连接');
    expect(find.byKey(_hostKey), findsNothing);
    await _save(tester);
    expect(service.saves.single.mode, NetworkProxyMode.direct);
    expect(service.saves.single.host, isEmpty);
    expect(service.saves.single.port, 7890);
  });

  testWidgets(
    'Back cancels unsaved edits and reopening restores persisted values',
    (tester) async {
      final service = _PageService();
      await _open(tester, service);
      await _select(tester, '手动 HTTP 代理');
      await tester.enterText(find.byKey(_hostKey), 'unsaved.proxy');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(service.saves, isEmpty);
      expect(find.byType(NetworkProxyPage), findsNothing);
      await tester.tap(find.text('Open proxy settings'));
      await tester.pumpAndSettle();
      expect(find.text('跟随系统（默认）'), findsOneWidget);
      expect(find.byKey(_hostKey), findsNothing);
    },
  );

  testWidgets('repeated Save taps during an outstanding write are ignored', (
    tester,
  ) async {
    final service = _PageService()..pendingSave = Completer<void>();
    await _open(tester, service);
    await _save(tester);
    await tester.tap(find.byKey(_saveKey));
    await tester.tap(find.byKey(_saveKey));
    await tester.pump();
    expect(service.saves, hasLength(1));
    expect(find.text('保存中…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(_saveKey)).onPressed, isNull);
    service.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(find.text('已保存，完全退出并重新启动应用后生效。'), findsOneWidget);
  });

  testWidgets('failed save reports failure and allows a successful retry', (
    tester,
  ) async {
    final service = _PageService()..failSave = true;
    await _open(tester, service);
    await _select(tester, '直接连接');
    await _save(tester);
    expect(find.text('保存失败，请重试；当前网络设置未改变。'), findsOneWidget);
    expect(service.stored.mode, NetworkProxyMode.system);
    service.failSave = false;
    await _save(tester);
    expect(service.saves, hasLength(2));
    expect(service.stored.mode, NetworkProxyMode.direct);
    expect(find.text('已保存，完全退出并重新启动应用后生效。'), findsOneWidget);
  });

  testWidgets('corrupt stored settings remain repairable', (tester) async {
    final service = _PageService()..failLoad = true;
    await _open(tester, service);
    expect(find.text('原代理设置无法读取，请重新选择并保存，然后重启应用。'), findsOneWidget);
    await _select(tester, '直接连接');
    await _save(tester);
    expect(service.saves.single.mode, NetworkProxyMode.direct);
  });

  testWidgets('Back during save does not setState on disposed page', (
    tester,
  ) async {
    final service = _PageService()..pendingSave = Completer<void>();
    await _open(tester, service);
    await _save(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    service.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(NetworkProxyPage), findsNothing);
    expect(find.text('Open proxy settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(service.saves, hasLength(1));
  });

  testWidgets('Back while initial settings load is pending is safe', (
    tester,
  ) async {
    final service = _PageService()
      ..pendingLoad = Completer<NetworkProxySettings>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NetworkProxyPage(service: service),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    service.pendingLoad!.complete(
      const NetworkProxySettings(
        mode: NetworkProxyMode.manual,
        host: 'proxy.local',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NetworkProxyPage), findsNothing);
    expect(tester.takeException(), isNull);
    expect(service.saves, isEmpty);
  });

  testWidgets(
    'small screen and large text remain scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _PageService();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: NetworkProxyPage(service: service),
        ),
      );
      await tester.pumpAndSettle();
      await _select(tester, '手动 HTTP 代理');
      await tester.enterText(find.byKey(_hostKey), '127.0.0.1');
      await tester.enterText(find.byKey(_portKey), '7890');
      await _save(tester);
      expect(service.saves.single.mode, NetworkProxyMode.manual);
      await tester.ensureVisible(
        find.byKey(const Key('network-proxy-message')),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
