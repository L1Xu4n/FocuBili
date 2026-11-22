import 'package:flutter/material.dart';

import '../../core/widgets/drag_checkbox_options.dart';
import '../../services/local_export_service.dart';
import '../../services/unified_export_service.dart';
import 'data_transfer_page.dart';

/// One deliberate local export, with personal data scope visible beforehand.
class UnifiedExportPage extends StatefulWidget {
  const UnifiedExportPage({
    super.key,
    this.service,
    this.saveService = const LocalExportService(),
  });
  final UnifiedExportService? service;
  final LocalExportService saveService;

  @override
  State<UnifiedExportPage> createState() => _UnifiedExportPageState();
}

class _UnifiedExportPageState extends State<UnifiedExportPage> {
  final _selected = {...UnifiedExportSection.values};
  bool _exporting = false;
  String? _status;

  Future<void> _export() async {
    if (_exporting || _selected.isEmpty) return;
    final selected = Set<UnifiedExportSection>.of(_selected);
    setState(() {
      _exporting = true;
      _status = null;
    });
    try {
      final package = await (widget.service ?? UnifiedExportService())
          .buildPackage(sections: selected);
      if (!mounted) return;
      final path = await widget.saveService.save(
        fileName: package.fileName,
        bytes: package.bytes,
        dialogTitle: '保存焦点哔哩资料包',
      );
      if (!mounted) return;
      setState(
        () => _status = path == null
            ? '已取消保存。'
            : '已导出 ${package.sections.length} 类资料。${package.warnings.isEmpty ? '' : '\n${package.warnings.join('\n')}'}',
      );
      if (path != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('已导出文件')));
      }
    } on LocalExportException catch (error) {
      if (mounted) {
        setState(
          () => _status = '${error.message}\n诊断代码：${error.diagnosticCode}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _status = '资料包生成失败，请检查本机存储后重试；也可取消勾选异常项目后单独导出。');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _setSectionsChecked(int first, int last, bool checked) {
    if (_exporting) return;
    setState(() {
      for (var index = first; index <= last; index++) {
        final section = UnifiedExportSection.values[index];
        checked ? _selected.add(section) : _selected.remove(section);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('统一导出')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: DragCheckboxOptions(
          itemCount: UnifiedExportSection.values.length,
          checkedAt: (index) =>
              _selected.contains(UnifiedExportSection.values[index]),
          onRangeChanged: _setSectionsChecked,
          enabled: !_exporting,
          builder: (context, controller, physics) => ListView(
            controller: controller,
            physics: physics,
            padding: const EdgeInsets.all(16),
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '将所选本机资料保存为 ZIP 文件，包含可阅读的 JSON、Markdown 和笔记截图。登录凭据、Cookie、Token 一律不包含。\n\n资料包可能包含个人笔记和观看记录，请妥善保存。',
                  ),
                ),
              ),
              TextButton(
                key: const Key('unified-export-select-all'),
                onPressed: _exporting
                    ? null
                    : () => setState(() {
                        if (_selected.length ==
                            UnifiedExportSection.values.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(UnifiedExportSection.values);
                        }
                      }),
                child: Text(
                  _selected.length == UnifiedExportSection.values.length
                      ? '取消全选'
                      : '全选',
                ),
              ),
              for (final (index, section)
                  in UnifiedExportSection.values.indexed)
                DragCheckboxTile(
                  key: ValueKey('unified-export-${section.name}'),
                  index: index,
                  value: _selected.contains(section),
                  title: Text(section.label),
                  subtitle: section == UnifiedExportSection.subtitles
                      ? const Text('只导出本次运行仍有效的已载入字幕，不会联网获取')
                      : section == UnifiedExportSection.history
                      ? const Text('包含当前设备可读取的进度和历史，不含登录会话')
                      : null,
                  onChanged: _exporting
                      ? null
                      : (checked) => _setSectionsChecked(index, index, checked),
                ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '视频媒体文件不打包，已下载视频请在离线视频页面导出。导入统一数据包可补充本机缺失的项目，其中可恢复的内容以导入预览为准。',
                ),
              ),
              FilledButton.icon(
                key: const Key('unified-export-save'),
                onPressed: _exporting || _selected.isEmpty ? null : _export,
                icon: _exporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download_outlined),
                label: Text(_exporting ? '正在生成资料包…' : '导出所选资料'),
              ),
              TextButton(
                onPressed: _exporting
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const DataTransferPage(),
                        ),
                      ),
                child: const Text('前往数据导入与导出'),
              ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _status!,
                    key: const Key('unified-export-status'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
