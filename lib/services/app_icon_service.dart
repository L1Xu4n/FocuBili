import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 应用图标管理：默认图标 + 用户自定义图标（任务栏 + 可选桌面快捷方式）。
///
/// 默认图标与安装程序、系统任务栏用的是同一份
/// `windows/runner/resources/app_icon.ico`（打包进 `assets/icon/app_icon.ico`），
/// 自定义图标只在用户主动选择后生效，且不改安装目录里的文件。
class AppIconService {
  const AppIconService();

  static const String iconPathKey = 'appearance.custom_icon_path';
  static const String shortcutKey = 'appearance.desktop_shortcut';

  /// 自定义图标落地目录：`%APPDATA%\FocuBili`。
  static Directory get iconDirectory {
    final String? appData = Platform.environment['APPDATA'];
    final String base = appData == null || appData.isEmpty
        ? Directory.systemTemp.path
        : appData;
    return Directory('$base${Platform.pathSeparator}FocuBili');
  }

  /// 默认图标在本地的落地路径（首次调用时从 assets 复制出来）。
  static Future<String> ensureDefaultIconFile() async {
    final Directory dir = iconDirectory;
    await dir.create(recursive: true);
    final File target = File(
      '${dir.path}${Platform.pathSeparator}default_app_icon.ico',
    );
    if (!await target.exists() || (await target.length()) == 0) {
      final ByteData data = await rootBundle.load('assets/icon/app_icon.ico');
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return target.path;
  }

  /// 把任意图片缩到 256×256 并包成 ICO（Vista+ 支持 PNG 内嵌）。
  static Future<Uint8List> buildIco(Uint8List source) async {
    final ui.Codec codec = await ui.instantiateImageCodec(
      source,
      targetWidth: 256,
      targetHeight: 256,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? png = await frame.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final Uint8List pngBytes = png!.buffer.asUint8List();
    final ByteData header = ByteData(22);
    header.setUint16(0, 0, Endian.little); // reserved
    header.setUint16(2, 1, Endian.little); // type = icon
    header.setUint16(4, 1, Endian.little); // 图像数量
    header.setUint8(6, 0); // 宽度 0 表示 256
    header.setUint8(7, 0); // 高度
    header.setUint8(8, 0); // 调色板
    header.setUint8(9, 0); // 保留
    header.setUint16(10, 1, Endian.little); // 色彩平面
    header.setUint16(12, 32, Endian.little); // 位深
    header.setUint32(14, pngBytes.length, Endian.little);
    header.setUint32(18, 22, Endian.little); // 数据偏移
    return Uint8List.fromList(<int>[
      ...header.buffer.asUint8List(),
      ...pngBytes,
    ]);
  }

  /// 应用自定义图标：写 ICO → 改任务栏 → 可选创建桌面快捷方式 → 持久化。
  Future<void> applyCustomIcon(
    File source, {
    required bool createShortcut,
  }) async {
    final Uint8List bytes = await source.readAsBytes();
    final Uint8List ico = await buildIco(bytes);
    final Directory dir = iconDirectory;
    await dir.create(recursive: true);
    final File target = File(
      '${dir.path}${Platform.pathSeparator}custom_app_icon.ico',
    );
    await target.writeAsBytes(ico, flush: true);
    await windowManager.setIcon(target.path);
    if (createShortcut) {
      await createDesktopShortcut(iconPath: target.path);
    } else {
      await removeDesktopShortcut();
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(iconPathKey, target.path);
    await prefs.setBool(shortcutKey, createShortcut);
  }

  /// 恢复默认图标（安装程序与任务栏使用同一份默认图标）。
  Future<void> resetToDefault() async {
    final String path = await ensureDefaultIconFile();
    await windowManager.setIcon(path);
    await removeDesktopShortcut();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(iconPathKey);
    await prefs.setBool(shortcutKey, false);
  }

  /// 启动时套用上次保存的自定义图标。
  Future<void> restoreOnStartup() async {
    if (!Platform.isWindows) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? path = prefs.getString(iconPathKey);
    if (path == null || path.isEmpty) return;
    if (!await File(path).exists()) return;
    try {
      await windowManager.setIcon(path);
    } catch (_) {
      // 图标文件损坏时保持默认图标，不影响启动。
    }
  }

  /// 桌面快捷方式路径。
  static String? get desktopShortcutPath {
    final String? profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) return null;
    return '$profile${Platform.pathSeparator}Desktop'
        '${Platform.pathSeparator}FocuBili.lnk';
  }

  /// 在桌面创建带自定义图标的快捷方式（指向当前可执行文件）。
  Future<void> createDesktopShortcut({required String iconPath}) async {
    final String? lnk = desktopShortcutPath;
    if (lnk == null) return;
    final String exe = Platform.resolvedExecutable;
    final String workDir = File(exe).parent.path;
    final String script =
        '''
\$ws = New-Object -ComObject WScript.Shell
\$sc = \$ws.CreateShortcut('$lnk')
\$sc.TargetPath = '$exe'
\$sc.WorkingDirectory = '$workDir'
\$sc.IconLocation = '$iconPath'
\$sc.Description = 'FocuBili 焦点哔哩'
\$sc.Save()
''';
    final File tmp = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'focubili_shortcut.ps1',
    );
    await tmp.writeAsString(script, flush: true);
    await Process.run('powershell', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      tmp.path,
    ]);
    try {
      await tmp.delete();
    } catch (_) {}
  }

  /// 删除桌面快捷方式（只删我们自己建的这一个）。
  Future<void> removeDesktopShortcut() async {
    final String? lnk = desktopShortcutPath;
    if (lnk == null) return;
    final File file = File(lnk);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
