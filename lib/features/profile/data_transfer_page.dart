import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/layout/adaptive_page_frame.dart';
import '../../services/bilibili_auth_service.dart';
import '../../services/data_transfer_file_service.dart';
import '../../services/settings_transfer_service.dart';

/// 提供用户主动操作的设置与登录迁移入口，敏感内容不进入剪贴板或诊断。
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
    } on BilibiliAuthException catch (error) {
      _message(error.message);
    } catch (_) {
      _message('操作未完成，请检查文件、网络或存储权限后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 显示结果而不包含导入导出文件的内容或完整路径。
  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 通过系统保存窗口写入 JSON，取消选择时不提示导出成功。
  Future<void> _save(String name, String content) async {
    if (await widget.fileService.saveJson(name, content)) {
      _message('导出完成，请妥善保存文件。');
    }
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

  /// 导出设置白名单，账号、协议状态和学习数据由各自功能管理。
  Future<void> _exportSettings() => _run(() async {
    await _save(
      'FocuBili-settings.json',
      await widget.settingsService.exportSettings(),
    );
  });

  /// 完整验证文件并展示影响范围，确认后合并设置，提示重启应用。
  Future<void> _importSettings() => _run(() async {
    final source = await _pick();
    if (source == null || !mounted) return;
    final values = widget.settingsService.parseSettings(source);
    if (!await _confirm(
      '导入设置？',
      '将替换文件中的 ${values.length} 项设置，包括账号只读、焦点订阅和后台检查等开关（如文件包含）。未列出的设置保持原值。登录状态、订阅源、笔记、学习清单和历史记录保留。导入后请重启 APP。',
      '确认导入',
    )) {
      return;
    }
    await widget.settingsService.importSettings(values);
    _message('设置已导入，请重启 APP 以应用设置。');
  });

  /// 说明明文登录文件的敏感性，用户确认后才读取稳定会话并写入自选位置。
  Future<void> _exportLogin() => _run(() async {
    if (!await _confirm(
      '导出登录信息？',
      '文件包含可用于登录账号的明文 Cookie。请只保存在你信任的位置，不要分享、上传或发送给他人。',
      '我已了解，导出',
    )) {
      return;
    }
    final cookie = await _auth.readCookieForExport();
    await _save(
      'FocuBili-login-private.json',
      jsonEncode({
        'format': 'focubili-login',
        'schemaVersion': 1,
        'cookie': cookie,
      }),
    );
  });

  /// 验证登录文件并明确确认切换账号，官方校验成功后才复用现有会话事务写入。
  Future<void> _importLogin() => _run(() async {
    final source = await _pick();
    if (source == null || !mounted) return;
    final root = jsonDecode(source);
    if (root is! Map ||
        root['format'] != 'focubili-login' ||
        root['schemaVersion'] != 1 ||
        root['cookie'] is! String ||
        (root['cookie'] as String).length > 65536) {
      throw const FormatException();
    }
    if (!await _confirm(
      '导入登录信息？',
      '请仅导入你自己的登录文件。应用将连接 B 站验证，成功后替换当前登录账号；失效文件或网络验证失败不会切换账号。',
      '验证并导入',
    )) {
      return;
    }
    await _auth.loginWithCookie(root['cookie'] as String);
    _message('登录信息已导入，请返回“我的”页面刷新账号。');
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
                  subtitle: const Text('先检查文件，确认后合并；重启生效'),
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
                  subtitle: const Text('敏感明文文件，请妥善保管'),
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
