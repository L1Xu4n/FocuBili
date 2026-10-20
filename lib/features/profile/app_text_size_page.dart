import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/theme/app_text_scale.dart';
import '../../services/app_text_scale_service.dart';
import 'app_text_scale_controller.dart';

class AppTextSizePage extends StatefulWidget {
  const AppTextSizePage({super.key});
  @override
  State<AppTextSizePage> createState() => _AppTextSizePageState();
}

class _AppTextSizePageState extends State<AppTextSizePage> {
  AppTextScaleController? _controller;
  bool _ownsController = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = AppTextScaleScope.maybeOf(context)?.controller;
    _ownsController = _controller == null;
    _controller ??= AppTextScaleController();
    unawaited(_controller!.initialize());
  }

  Future<void> _save(double value) async {
    if (!await _controller!.setScale(value) && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('文字大小保存失败，已恢复上次设置。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    Widget content = ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('界面文字大小')),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '当前 ${(controller.scale * 100).round()}%',
                key: const Key('ui-text-size-value'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              const Text('在系统字号基础上调整界面文字，图标和视频大小不变。播放器字幕仍使用自己的字号设置。'),
              Slider(
                key: const Key('ui-text-size-slider'),
                min: AppTextScaleService.minimum,
                max: AppTextScaleService.maximum,
                divisions: 12,
                value: controller.scale,
                label: '${(controller.scale * 100).round()}%',
                semanticFormatterCallback: (value) =>
                    '${(value * 100).round()}%',
                onChanged: controller.preview,
                onChangeEnd: (value) => unawaited(_save(value)),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '文字预览',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '让每一次观看，都有所收获。',
                        key: Key('ui-text-size-preview'),
                        style: TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Aa 0123456789 · 默认 100% 保留系统字号',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('reset-ui-text-size'),
                  onPressed: () => unawaited(_save(1)),
                  icon: const Icon(Icons.restore),
                  label: const Text('恢复默认 100%'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (_ownsController) {
      content = AppTextScale(controller: controller, child: content);
    }
    return content;
  }

  @override
  void dispose() {
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }
}
