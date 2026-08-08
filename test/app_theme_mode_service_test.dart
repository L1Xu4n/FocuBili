import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/app_theme_mode_controller.dart';
import 'package:focubili/services/app_theme_mode_service.dart';

/// 模拟本地写入失败，用来确认控制器能够恢复切换前的主题。
class _FailingThemeModeService extends AppThemeModeService {
  /// 测试从一个已保存的浅色模式开始。
  @override
  Future<ThemeMode> load() async => ThemeMode.light;

  /// 每次保存都抛错，模拟设备存储不可用。
  @override
  Future<void> save(ThemeMode mode) async {
    throw StateError('mock save failure');
  }
}

/// 验证主题偏好的默认值、持久化和失败恢复行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每项测试从空白本地偏好开始，避免主题选择互相影响。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证首次安装没有任何记录时默认跟随操作系统。
  test('主题偏好首次读取默认跟随系统', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppThemeModeService service = AppThemeModeService(
      preferencesLoader: () async => preferences,
    );

    expect(await service.load(), ThemeMode.system);
  });

  /// 验证三种模式使用稳定字符串保存，并能由新服务实例正确恢复。
  test('主题偏好保存并恢复浅色深色和跟随系统', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppThemeModeService service = AppThemeModeService(
      preferencesLoader: () async => preferences,
    );

    await service.save(ThemeMode.light);
    expect(await service.load(), ThemeMode.light);
    await service.save(ThemeMode.dark);
    expect(await service.load(), ThemeMode.dark);
    await service.save(ThemeMode.system);
    expect(await service.load(), ThemeMode.system);
  });

  /// 验证旧版或损坏的未知字符串不会阻止启动，而是安全回退系统模式。
  test('主题偏好未知值回退跟随系统', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'appearance.theme_mode': 'unknown-mode',
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppThemeModeService service = AppThemeModeService(
      preferencesLoader: () async => preferences,
    );

    expect(await service.load(), ThemeMode.system);
  });

  /// 验证控制器先立即换色，再把深色选择持久化到本地。
  test('主题控制器立即应用并保存选择', () async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final AppThemeModeService service = AppThemeModeService(
      preferencesLoader: () async => preferences,
    );
    final AppThemeModeController controller = AppThemeModeController(
      service: service,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final Future<bool> saving = controller.setMode(ThemeMode.dark);
    expect(controller.mode, ThemeMode.dark);
    expect(controller.saving, isTrue);
    expect(await saving, isTrue);
    expect(await service.load(), ThemeMode.dark);
    expect(controller.saving, isFalse);
  });

  /// 验证保存失败时界面不会停留在一个重启后无法恢复的错误选择上。
  test('主题控制器保存失败恢复旧选择', () async {
    final AppThemeModeController controller = AppThemeModeController(
      service: _FailingThemeModeService(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(await controller.setMode(ThemeMode.dark), isFalse);
    expect(controller.mode, ThemeMode.light);
    expect(controller.saving, isFalse);
  });
}
