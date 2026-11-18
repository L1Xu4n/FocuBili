import 'package:flutter/material.dart';
import '../../services/video_tag_preferences.dart';

class VideoTagSetting extends StatefulWidget {
  const VideoTagSetting({super.key});
  @override
  State<VideoTagSetting> createState() => _VideoTagSettingState();
}

class _VideoTagSettingState extends State<VideoTagSetting> {
  VideoTagMode? mode;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final found = await VideoTagPreferences.load();
    if (mounted) setState(() => mode = found);
  }

  Future<void> _choose() async {
    final value = await showDialog<VideoTagMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('视频标签'),
        children: [
          for (final m in VideoTagMode.values)
            SimpleDialogOption(
              key: Key('video-tag-choice-${m.name}'),
              onPressed: () => Navigator.pop(c, m),
              child: Semantics(
                selected: m == mode,
                child: Row(
                  children: [
                    Icon(
                      m == mode
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(m.label)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || value == null || value == mode) return;
    setState(() => saving = true);
    final ok = await VideoTagPreferences.save(value);
    if (!mounted) return;
    setState(() {
      if (ok) mode = value;
      saving = false;
    });
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('视频标签设置未保存，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.sell_outlined),
    title: const Text('视频标签'),
    subtitle: Text(mode?.label ?? '正在读取…'),
    trailing: const Icon(Icons.chevron_right),
    onTap: mode == null || saving ? null : _choose,
  );
}
