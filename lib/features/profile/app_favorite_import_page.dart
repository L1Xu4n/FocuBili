import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/layout/adaptive_page_frame.dart';
import '../../models/account_collection.dart';
import '../../models/app_favorite.dart';
import '../../services/app_favorite_import_service.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';

/// 选择 B 站来源收藏夹和本机目标收藏夹，显示导入进度与部分完成结果。
class AppFavoriteImportPage extends StatefulWidget {
  /// 接收现有本机收藏服务和可替换的账号读取服务。
  const AppFavoriteImportPage({
    super.key,
    required this.favoritesService,
    this.accountService,
  });
  final AppFavoritesService favoritesService;
  final BilibiliAccountDataService? accountService;

  /// 创建独立管理来源、目标和导入状态的页面状态。
  @override
  State<AppFavoriteImportPage> createState() => _AppFavoriteImportPageState();
}

class _AppFavoriteImportPageState extends State<AppFavoriteImportPage> {
  late final BilibiliAccountDataService _accountService;
  List<FavoriteFolder> _sources = [];
  List<AppFavoriteFolder> _targets = [];
  FavoriteFolder? _source;
  String _targetId = '';
  final _name = TextEditingController();
  bool _loading = true, _running = false, _stopRequested = false;
  int _imported = 0;
  String? _message;

  /// 读取当前账号的 B 站收藏夹和现有软件收藏夹。
  @override
  void initState() {
    super.initState();
    _accountService = widget.accountService ?? BilibiliAccountDataService();
    unawaited(_load());
  }

  /// 加载失败时保留错误说明，并允许用户重新读取。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final sources = await _accountService.loadFavoriteFolders();
      final targets = await widget.favoritesService.loadFolders();
      if (!mounted) return;
      setState(() {
        _sources = sources.items;
        _targets = targets.toList();
        _loading = false;
        _message = sources.isSuccess ? null : sources.message;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = '无法读取收藏夹，请重试。';
        });
      }
    }
  }

  /// 切换来源，并给新建软件收藏夹填入来源名称。
  void _selectSource(FavoriteFolder source) {
    setState(() {
      _source = source;
      _name.text = source.title;
      _message = null;
    });
  }

  /// 开始逐页导入；完成后保留结果并将新建文件夹加入目标选项以便重试。
  Future<void> _import() async {
    if (_running ||
        _source == null ||
        (_targetId.isEmpty && _name.text.trim().isEmpty)) {
      return;
    }
    setState(() {
      _running = true;
      _stopRequested = false;
      _imported = 0;
      _message = null;
    });
    final target = _targetId.isEmpty
        ? null
        : _targets.firstWhere((e) => e.id == _targetId);
    final result =
        await AppFavoriteImportService(
          accountService: _accountService,
          favoritesService: widget.favoritesService,
        ).importFolder(
          source: _source!,
          target: target,
          newFolderName: _name.text.trim(),
          isCancelled: () => _stopRequested || !mounted,
          onProgress: (count) {
            if (mounted) setState(() => _imported = count);
          },
        );
    if (!mounted) return;
    setState(() {
      _running = false;
      _message = result.message == null ? null : result.summary;
      if (result.folder != null) {
        if (!_targets.any((e) => e.id == result.folder!.id)) {
          _targets.add(result.folder!);
        }
        _targetId = result.folder!.id;
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            result.message == null
                ? '导入完成，新增 ${result.imported} 个视频'
                : result.summary,
          ),
          duration: const Duration(seconds: 2),
          persist: false,
        ),
      );
  }

  /// 请求在当前读取或保存完成后停止，已经导入的视频保持不变。
  void _stop() => setState(() => _stopRequested = true);

  /// 离开页面时撤销后续导入并释放名称输入资源。
  @override
  void dispose() {
    _stopRequested = true;
    _name.dispose();
    super.dispose();
  }

  /// 单独滚动来源列表，选择来源后不移动底部的导入选项与操作。
  Widget _buildSourceList() {
    return ListView(
      key: const Key('favorite-import-sources'),
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text('将收藏视频复制到本机软件收藏夹。不会修改 B 站收藏；重复视频和失效视频会跳过。'),
        const SizedBox(height: 12),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_message!),
          ),
        if (_sources.isEmpty) ...<Widget>[
          if (_message == null) const Text('当前 B 站账号没有收藏夹。'),
          TextButton(onPressed: _load, child: const Text('重新读取')),
        ],
        for (final source in _sources)
          ListTile(
            selected: _source?.mediaId == source.mediaId,
            leading: Icon(
              _source?.mediaId == source.mediaId
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: Text(source.title),
            subtitle: Text(
              source.isAvailable ? '${source.mediaCount} 个视频' : '收藏夹不可用',
            ),
            enabled: !_running && source.isAvailable,
            // 选择来源只更新草稿名称，实际导入仍由固定按钮触发。
            onTap: () => _selectSource(source),
          ),
      ],
    );
  }

  /// 常驻目标、名称与开始或停止按钮；宽屏并排显示目标和名称。
  Widget _buildImportControls() {
    final enabled = !_running && _source != null;
    final target = DropdownButtonFormField<String>(
      key: ValueKey('import-target-$_targetId'),
      initialValue: _targetId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '导入到', isDense: true),
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem(value: '', child: Text('新建软件收藏夹')),
        for (final folder in _targets)
          DropdownMenuItem(
            value: folder.id,
            child: Text(folder.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      // 目标切换后立即刷新名称输入的显隐，不提交收藏内容。
      onChanged: enabled
          ? (value) => setState(() => _targetId = value ?? '')
          : null,
    );
    final name = TextField(
      controller: _name,
      enabled: enabled,
      maxLength: 20,
      decoration: const InputDecoration(
        labelText: '新收藏夹名称',
        isDense: true,
        counterText: '',
      ),
      // 根据名称是否为空即时启用或禁用导入按钮。
      onChanged: (_) => setState(() {}),
    );
    return SafeArea(
      top: false,
      child: Padding(
        key: const Key('favorite-import-controls'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              // 宽屏将两个输入并排，手机按自然高度排列，避免列表把操作推走。
              builder: (context, constraints) =>
                  constraints.maxWidth >= 560 && _targetId.isEmpty
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: target),
                        const SizedBox(width: 12),
                        Expanded(child: name),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        target,
                        if (_targetId.isEmpty) ...[
                          const SizedBox(height: 8),
                          name,
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            if (_running) ...[
              const LinearProgressIndicator(),
              Text(
                _stopRequested
                    ? '正在停止，已导入 $_imported 个…'
                    : '已导入 $_imported 个视频…',
              ),
              TextButton(
                onPressed: _stopRequested ? null : _stop,
                child: const Text('停止导入'),
              ),
            ] else
              FilledButton.icon(
                key: const Key('start-favorite-import'),
                onPressed:
                    !enabled || (_targetId.isEmpty && _name.text.trim().isEmpty)
                    ? null
                    : _import,
                icon: const Icon(Icons.download_rounded),
                label: Text(_source == null ? '请先选择来源收藏夹' : '开始导入'),
              ),
          ],
        ),
      ),
    );
  }

  /// 来源列表占用剩余空间，导入选项和按钮始终留在页面底部。
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _running) _stop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('从 B 站收藏夹导入')),
        body: AdaptivePageFrame(
          maxWidth: 900,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: <Widget>[
                    Expanded(child: _buildSourceList()),
                    const Divider(height: 1),
                    _buildImportControls(),
                  ],
                ),
        ),
      ),
    );
  }
}
