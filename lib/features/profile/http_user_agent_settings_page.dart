import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../services/http_user_agent_preferences.dart';

/// Optional, device-local compatibility preference, independent from login
/// and playback source or authorization settings.
class HttpUserAgentSettingsPage extends StatefulWidget {
  const HttpUserAgentSettingsPage({
    super.key,
    this.preferences = const HttpUserAgentPreferences(),
  });

  final HttpUserAgentPreferences preferences;

  @override
  State<HttpUserAgentSettingsPage> createState() =>
      _HttpUserAgentSettingsPageState();
}

class _HttpUserAgentSettingsPageState extends State<HttpUserAgentSettingsPage> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  String? _savedValue;
  String? _inputError;
  String? _storageMessage;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await widget.preferences.load();
      if (!mounted) return;
      _controller.text = saved ?? '';
      setState(() {
        _savedValue = saved;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _storageMessage = '无法读取保存的设置。请求将继续使用原来的默认标识。';
      });
    }
  }

  Future<void> _save(String raw) async {
    if (_loading || _saving) return;
    try {
      HttpUserAgentInput.normalize(raw);
    } on FormatException catch (error) {
      setState(() => _inputError = error.message);
      // At large type sizes the Save button can be a viewport below its field.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.minScrollExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
      return;
    }
    setState(() {
      _inputError = null;
      _storageMessage = null;
      _saving = true;
    });
    try {
      final saved = await widget.preferences.save(raw);
      if (!mounted) return;
      _controller.text = saved ?? '';
      setState(() {
        _saving = false;
        _savedValue = saved;
        _storageMessage = saved == null ? '已恢复默认。' : '已保存，下次请求生效。';
      });
      FocusScope.of(context).unfocus();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _storageMessage = '未能确认保存。请重试。';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('HTTP User-Agent')),
      body: SafeArea(
        top: false,
        child: AdaptivePageFrame(
          maxWidth: 680,
          child: ListView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Text('请求标识', style: theme.textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                _loading
                    ? '正在读取…'
                    : _savedValue == null
                    ? '当前使用默认标识'
                    : '当前使用自定义标识',
                key: const Key('http-user-agent-status'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('http-user-agent-input'),
                controller: _controller,
                enabled: !_loading && !_saving,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                minLines: 1,
                maxLines: 3,
                maxLength: HttpUserAgentInput.maxLength,
                maxLengthEnforcement: MaxLengthEnforcement.none,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(
                    HttpUserAgentInput.maxLength + 1,
                  ),
                ],
                onSubmitted: _save,
                onChanged: (_) {
                  if (_inputError != null || _storageMessage != null) {
                    setState(() {
                      _inputError = null;
                      _storageMessage = null;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: '自定义 User-Agent',
                  hintText: '留空使用各请求原有的默认值',
                  border: const OutlineInputBorder(),
                  errorText: _inputError,
                  errorMaxLines: 4,
                ),
              ),
              const SizedBox(height: 8),
              const Text('单行 ASCII，只保存在本机。仅在后续符合条件的请求中生效。'),
              if (_storageMessage case final message?) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    key: const Key('http-user-agent-feedback'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    key: const Key('http-user-agent-reset'),
                    onPressed: _saving || _loading ? null : () => _save(''),
                    child: const Text('恢复默认'),
                  ),
                  FilledButton(
                    key: const Key('http-user-agent-save'),
                    onPressed: _saving || _loading
                        ? null
                        : () => _save(_controller.text),
                    child: Text(_saving ? '正在保存…' : '保存'),
                  ),
                ],
              ),
              const Divider(height: 40),
              Text('作用范围', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('公开的视频详情、标签、视频与 UP 主搜索及搜索建议。'),
              const SizedBox(height: 8),
              const Text(
                'Android、Windows、macOS 和 Linux：仅用于明确普通投稿的 '
                '360P、480P、720P 播放信息请求。Android 下次打开视频或主动切换画质时读取。'
                '其他档位或权限不明确的内容使用默认值。',
              ),
              const SizedBox(height: 8),
              const Text(
                '不影响登录、鉴权、媒体传输、课程、付费或受保护内容。'
                '请求被拒绝时不会切换标识重试。',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
