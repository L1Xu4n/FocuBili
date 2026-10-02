import 'package:flutter/material.dart';

import '../../models/playback_preferences.dart';

/// Applies every speed edit immediately without a separate save/cancel step.
class PlaybackSpeedsDialog extends StatefulWidget {
  /// Receives the saved menu and its checked persistence callback.
  const PlaybackSpeedsDialog({
    super.key,
    required this.speeds,
    required this.onChanged,
  });
  final List<double> speeds;
  final Future<void> Function(List<double>) onChanged;

  /// Creates the local editor state.
  @override
  State<PlaybackSpeedsDialog> createState() => _PlaybackSpeedsDialogState();
}

class _PlaybackSpeedsDialogState extends State<PlaybackSpeedsDialog> {
  final _input = TextEditingController();
  late List<double> _speeds;
  String? _error;
  bool _saving = false;

  /// Sanitizes saved values before displaying editable chips.
  @override
  void initState() {
    super.initState();
    _speeds = PlaybackPreferences.normalizeSpeeds(widget.speeds);
  }

  /// Releases the numeric input controller when the dialog closes.
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Adds a valid unique rate with at most two decimal places, up to 5x.
  Future<void> _addSpeed() async {
    if (_saving) return;
    final text = _input.text.trim();
    final speed = double.tryParse(text);
    String? error;
    if (speed == null || !speed.isFinite || speed < 0.5 || speed > 5) {
      error = '请输入 0.5 到 5 之间的倍速';
    } else if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text)) {
      error = '最多保留两位小数';
    } else if (_speeds.contains(speed)) {
      error = '该倍速已存在';
    }
    setState(() => _error = error);
    if (error == null && await _applySpeeds([..._speeds, speed!]) && mounted) {
      _input.clear();
    }
  }

  /// Deletes any optional rate, protecting normal playback in code as well as UI.
  Future<void> _removeSpeed(double speed) async {
    if (speed == 1 || _saving) return;
    await _applySpeeds(_speeds.where((value) => value != speed).toList());
  }

  /// Commits edits serially and keeps the last saved list when storage rejects a write.
  Future<bool> _applySpeeds(List<double> speeds) async {
    final normalized = PlaybackPreferences.normalizeSpeeds(speeds);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onChanged(normalized);
      if (mounted) setState(() => _speeds = normalized);
      return true;
    } catch (_) {
      if (mounted) setState(() => _error = '倍速保存失败，请重试');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Builds a scrollable editor usable on narrow screens and with a keyboard.
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('自定义播放倍速')),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    scrollable: true,
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final speed in _speeds)
                InputChip(
                  key: Key('configured-speed-$speed'),
                  label: Text(PlaybackPreferences.speedLabel(speed)),
                  avatar: speed == 1
                      ? const Icon(Icons.lock_outline, size: 16)
                      : null,
                  onDeleted: speed == 1 || _saving
                      ? null
                      : () => _removeSpeed(speed),
                  deleteButtonTooltipMessage:
                      '删除 ${PlaybackPreferences.speedLabel(speed)}',
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('custom-playback-speed-input'),
                  controller: _input,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '倍速（0.5–5）',
                    suffixText: 'x',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addSpeed(),
                ),
              ),
              IconButton(
                key: const Key('add-playback-speed'),
                tooltip: '添加倍速',
                onPressed: _saving ? null : _addSpeed,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
