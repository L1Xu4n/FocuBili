import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/services/windows_clipboard_link_service.dart';

/// 验证 Windows 剪贴板检测开关默认保护隐私，并可在本机持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 旧版本没有设置记录时必须默认关闭，用户开启后重建服务仍能读取。
  test('Windows 剪贴板检测默认关闭并可持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final WindowsClipboardLinkPreferencesService service =
        WindowsClipboardLinkPreferencesService(
          preferencesLoader: () async => preferences,
        );

    expect(await service.loadEnabled(), isFalse);
    expect(await service.saveEnabled(true), isTrue);
    expect(await service.loadEnabled(), isTrue);
  });
}
