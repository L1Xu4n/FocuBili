import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/bilibili_interaction_service.dart';
import '../../services/cache_lifecycle.dart';

Future<FavoriteFolderEditable?> showFavoriteFolderEditDialog(
  BuildContext context, {
  required BilibiliInteractionService service,
  required int mediaId,
  required int ownerMid,
  required bool Function() isCurrent,
}) => showDialog<FavoriteFolderEditable>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _FavoriteFolderEditDialog(
    service: service,
    mediaId: mediaId,
    ownerMid: ownerMid,
    isCurrent: isCurrent,
  ),
);

class _FavoriteFolderEditDialog extends StatefulWidget {
  const _FavoriteFolderEditDialog({
    required this.service,
    required this.mediaId,
    required this.ownerMid,
    required this.isCurrent,
  });

  final BilibiliInteractionService service;
  final int mediaId;
  final int ownerMid;
  final bool Function() isCurrent;

  @override
  State<_FavoriteFolderEditDialog> createState() =>
      _FavoriteFolderEditDialogState();
}

class _FavoriteFolderEditDialogState extends State<_FavoriteFolderEditDialog> {
  final _title = TextEditingController();
  ModalRoute<dynamic>? _route;
  FavoriteFolderEditable? _original;
  bool? _private;
  String? _error;
  bool _loading = true, _saving = false;

  bool _current() => mounted && _route?.isCurrent == true && widget.isCurrent();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    _route = ModalRoute.of(context);
    unawaited(_load());
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.service.loadFavoriteFolderForEdit(
        mediaId: widget.mediaId,
        expectedMid: widget.ownerMid,
        isCurrent: _current,
      );
      if (!_current()) return;
      _title.text = result.title;
      setState(() {
        _original = result;
        _private = result.isPrivate;
        _loading = false;
      });
    } catch (error) {
      if (_current()) {
        setState(() {
          _error = _errorMessage(error, '无法读取收藏夹设置，请重新打开后重试。');
          _loading = false;
        });
      }
    }
  }

  String _errorMessage(Object error, String fallback) =>
      error is BilibiliInteractionException ? error.message : fallback;

  bool get _canSave {
    final original = _original;
    final title = _title.text.trim();
    return original != null &&
        _private != null &&
        !_saving &&
        title.isNotEmpty &&
        (_title.text == original.title || title.runes.length <= 20) &&
        (_title.text != original.title || _private != original.isPrivate);
  }

  Future<void> _save() async {
    if (!_canSave || !_current()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.service.editFavoriteFolder(
        mediaId: widget.mediaId,
        expectedMid: widget.ownerMid,
        original: _original!,
        title: _title.text,
        isPrivate: _private!,
        isCurrent: _current,
      );
      if (mounted && _current()) Navigator.pop(context, updated);
    } catch (error) {
      if (_current()) {
        setState(() {
          _saving = false;
          _error = _errorMessage(error, '未能确认保存，请关闭后重新打开查看。');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: CacheLifecycle.account,
    builder: (context, _, _) {
      final valid = widget.isCurrent();
      final busy = valid && _saving;
      return PopScope(
        canPop: !busy,
        child: AlertDialog(
          scrollable: true,
          title: const Text('编辑收藏夹'),
          content: !valid
              ? const Text('账号已变化，请关闭后重新打开。')
              : _loading
              ? const LinearProgressIndicator()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_original != null) ...[
                      TextField(
                        key: const Key('favorite-folder-edit-title'),
                        controller: _title,
                        enabled: !busy,
                        readOnly: !_original!.canRename,
                        maxLength: 20,
                        decoration: InputDecoration(
                          labelText: '收藏夹名称',
                          helperText: _original!.canRename
                              ? null
                              : 'B 站默认收藏夹不可改名',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 12),
                      const Text('可见性'),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('公开')),
                          ButtonSegment(value: true, label: Text('私密')),
                        ],
                        selected: {_private!},
                        onSelectionChanged: busy
                            ? null
                            : (value) =>
                                  setState(() => _private = value.single),
                      ),
                    ],
                    if (_error case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            if (valid && _original != null)
              FilledButton(
                key: const Key('favorite-folder-edit-save'),
                onPressed: _canSave ? () => unawaited(_save()) : null,
                child: Text(busy ? '保存中…' : '保存'),
              ),
          ],
        ),
      );
    },
  );
}
