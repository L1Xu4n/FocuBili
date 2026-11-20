import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/layout/adaptive_page_frame.dart';
import '../../services/bilibili_auth_service.dart';
import '../../services/data_transfer_file_service.dart';
import '../../services/settings_transfer_service.dart';
import 'settings_transfer_dialogs.dart';

/// 提供用户主动操作的设置与登录迁移入口，登录备份仅在明确确认后导出，凭据不明文显示或写入诊断。
class DataTransferPage extends StatefulWidget {
  /// 创建迁移页面，测试可以注入只使用合成数据的服务。
  const DataTransferPage({
    super.key,
    this.settingsService = const SettingsTransferService(),
    this.fileService = const DataTransferFileService(),
    this.authService,
  });
  final SettingsTransferService settingsService;
  final DataTransferFileService fileService;
  final BilibiliAuthService? authService;

  /// 创建迁移操作与确认弹窗的页面状态。
  @override
  State<DataTransferPage> createState() => _DataTransferPageState();
}

/// 串行执行用户选择的迁移操作，并以固定文案提示结果。
class _DataTransferPageState extends State<DataTransferPage> {
  bool _busy = false;
  late final _auth = widget.authService ?? BilibiliAuthService();

  /// 请求明确确认，取消与返回都不会执行后续操作。
  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  /// 防止重复点击，同时使用固定错误提示，避免异常内容带出登录信息。
  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } on FormatException {
      _message('文件格式不支持或内容损坏，未导入。');
    } on BilibiliAuthException {
      _message('登录信息不可用或验证失败，请检查登录状态和网络后重试。');
    } catch (_) {
      _message('操作未完成，请检查文件、网络或存储权限后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 显示结果而不包含导入导出文件的内容或完整路径。
  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 通过系统保存窗口写入 JSON，取消选择时不提示导出成功。
  Future<void> _save(String name, String content) async {
    if (await widget.fileService.saveJson(name, content) && _current) {
      _message('已导出文件');
    }
  }

  Future<void> _copy(String content) async {
    try {
      await Clipboard.setData(ClipboardData(text: content));
    } catch (_) {
      if (_current) _message('无法写入剪贴板，请重试或导出为文件。');
      return;
    }
    if (_current) _message('已复制到剪贴板');
  }

  /// 仅在用户选择单个本地文件后读取，先检查大小以避免无界加载。
  Future<String?> _pick() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: false,
    );
    if (result == null) return null;
    final chosen = result.files.single;
    final path = chosen.path;
    if (path == null || chosen.size > SettingsTransferService.maximumBytes) {
      throw const FormatException();
    }
    final file = File(path);
    if (await file.length() > SettingsTransferService.maximumBytes) {
      throw const FormatException();
    }
    return file.readAsString();
  }

  /// 文件和剪贴板都使用同一份设置白名单 JSON。
  Future<void> _exportSettings() => _run(() async {
    final method = await chooseDataTransferMethod(context, importing: false);
    if (!mounted || method == null || !_current) return;
    final source = await widget.settingsService.exportSettings();
    if (!_current) return;
    if (method == DataTransferMethod.file) {
      await _save('FocuBili-settings.json', source);
    } else {
      await _copy(source);
    }
  });

  bool get _current => mounted && ModalRoute.of(context)?.isCurrent != false;

  /// 两种来源都经过同一个解析器，经现有确认流程后才写入设置。
  Future<void> _importSettings() => _run(() async {
    final method = await chooseDataTransferMethod(context, importing: true);
    if (!mounted || method == null || !_current) return;
    final Map<String, Object>? values;
    if (method == DataTransferMethod.file) {
      final source = await _pick();
      if (source == null || !_current) return;
      values = widget.settingsService.parseSettings(source);
    } else {
      values = await showDialog<Map<String, Object>>(
        context: context,
        builder: (_) => DataTransferTextImportDialog<Map<String, Object>>(
          parse: widget.settingsService.parseSettings,
        ),
      );
    }
    if (!_current || values == null) return;
    final confirmed = await _confirm(
      '导入设置？',
      '将替换备份中的 ${values.length} 项设置，包括账号只读、焦点订阅和后台检查等开关（如备份包含）。未列出的设置保持原值。登录状态、订阅源、笔记、学习清单和历史记录保留。导入后请重启 APP。',
      '确认导入',
    );
    if (!confirmed || !_current) return;
    await widget.settingsService.importSettings(values);
    if (_current) _message('设置已导入，请重启 APP 以应用设置。');
  });

  /// 只在确认具体的明文文件/剪贴板目的地后读取当前稳定会话。
  Future<void> _exportLogin() => _run(() async {
    final method = await chooseDataTransferMethod(
      context,
      importing: false,
      login: true,
    );
    if (!mounted || method == null || !_current) return;
    final copying = method == DataTransferMethod.text;
    final confirmed = await _confirm(
      copying ? '复制登录信息？' : '导出登录信息？',
      copying
          ? '明文 Cookie 可用于登录你的账号。剪贴板历史或云同步可能保留副本，请只在可信设备间迁移，不要分享给他人。'
          : '文件包含可用于登录账号的明文 Cookie。请只保存在你信任的位置，不要分享、上传或发送给他人。',
      copying ? '我已了解，复制' : '我已了解，导出',
    );
    if (!confirmed || !_current || (copying && !_foreground)) return;
    final cookie = await _auth.readCookieForExport();
    if (!_current || (copying && !_foreground)) return;
    final source = jsonEncode({
      'format': 'focubili-login',
      'schemaVersion': 1,
      'cookie': cookie,
    });
    if (!copying) {
      await _save('FocuBili-login-private.json', source);
      return;
    }
    await _copy(source);
  });

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// 两种载体只接受现有登录 JSON 格式，解析错误不带出备份内容。
  static String _parseLogin(String source) {
    if (!SettingsTransferService.fitsTransferLimit(source)) {
      throw const FormatException();
    }
    final root = jsonDecode(source);
    if (root is! Map ||
        root['format'] != 'focubili-login' ||
        root['schemaVersion'] != 1 ||
        root['cookie'] is! String) {
      throw const FormatException();
    }
    final cookie = root['cookie'] as String;
    if (cookie.isEmpty || cookie.length > 65536) throw const FormatException();
    return cookie;
  }

  /// 登录文本仅保留在当次编辑中，通过格式校验和确认后才验证账号。
  Future<void> _importLogin() => _run(() async {
    final method = await chooseDataTransferMethod(
      context,
      importing: true,
      login: true,
    );
    if (!mounted || method == null || !_current) return;
    final String? cookie;
    final fromText = method == DataTransferMethod.text;
    if (fromText) {
      if (!_foreground) return;
      cookie = await showDialog<String>(
        context: context,
        builder: (_) => DataTransferTextImportDialog<String>(
          parse: _parseLogin,
          login: true,
        ),
      );
    } else {
      final source = await _pick();
      if (source == null || !_current) return;
      cookie = _parseLogin(source);
    }
    if (cookie == null || !_current || (fromText && !_foreground)) return;
    final confirmed = await _confirm(
      '导入登录信息？',
      fromText
          ? '请仅导入你自己的登录备份。应用将连接 B 站验证，成功后替换当前登录账号；失效备份或网络验证失败不会切换账号。'
          : '请仅导入你自己的登录文件。应用将连接 B 站验证，成功后替换当前登录账号；失效文件或网络验证失败不会切换账号。',
      '验证并导入',
    );
    if (!confirmed || !_current || (fromText && !_foreground)) return;
    await _auth.loginWithCookie(cookie);
    if (_current) _message('登录信息已导入，请返回“我的”页面刷新账号。');
  });

  /// 确认后仅重置设置白名单，保留用户内容与协议记录。
  Future<void> _reset() => _run(() async {
    if (!await _confirm(
      '重置所有设置？',
      '外观、播放器、弹幕、首页与我的布局等设置将恢复默认，焦点订阅和通知、后台检查将关闭。登录状态、协议记录、订阅源、笔记、学习清单、历史记录和离线文件保留。重置后请重启 APP。',
      '恢复默认设置',
    )) {
      return;
    }
    await widget.settingsService.resetSettings();
    _message('设置已重置，请重启 APP 以应用设置。');
  });

  /// 展示设置与账号的独立操作，处理中暂时禁用重复操作。
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('数据导入与导出')),
    body: AdaptivePageFrame(
      maxWidth: 900,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('导出设置'),
                  subtitle: const Text('外观、播放器、弹幕、布局等偏好'),
                  leading: const Icon(Icons.upload_file_outlined),
                  onTap: _busy ? null : _exportSettings,
                ),
                ListTile(
                  title: const Text('导入设置'),
                  subtitle: const Text('从文件或文本导入，确认后合并；重启生效'),
                  leading: const Icon(Icons.download_outlined),
                  onTap: _busy ? null : _importSettings,
                ),
              ],
            ),
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('导出登录信息'),
                  subtitle: const Text('通过文件或剪贴板迁移，请妥善保管'),
                  leading: const Icon(Icons.key_outlined),
                  onTap: _busy ? null : _exportLogin,
                ),
                ListTile(
                  title: const Text('导入登录信息'),
                  subtitle: const Text('官方验证成功后切换账号'),
                  leading: const Icon(Icons.login_rounded),
                  onTap: _busy ? null : _importLogin,
                ),
              ],
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('重置所有设置'),
              subtitle: const Text('恢复默认偏好，保留账号与学习数据'),
              leading: const Icon(Icons.restart_alt_rounded),
              onTap: _busy ? null : _reset,
            ),
          ),
        ],
      ),
    ),
  );
}
