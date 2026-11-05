import 'package:flutter/material.dart';

import '../../models/network_proxy_settings.dart';
import '../../services/network_proxy_service.dart';

/// Edits the next-start routing snapshot without interrupting active playback.
class NetworkProxyPage extends StatefulWidget {
  const NetworkProxyPage({super.key, this.service});
  final NetworkProxyService? service;
  @override
  State<NetworkProxyPage> createState() => _NetworkProxyPageState();
}

class _NetworkProxyPageState extends State<NetworkProxyPage> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '7890');
  NetworkProxyMode _mode = NetworkProxyMode.system;
  bool _loading = true;
  bool _saving = false;
  String? _message;
  NetworkProxyService get _service =>
      widget.service ?? NetworkProxyService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _service.load();
      if (!mounted) return;
      setState(() {
        _mode = settings.mode;
        _host.text = settings.host;
        _port.text = '${settings.port}';
      });
    } catch (_) {
      if (mounted) _message = '原代理设置无法读取，请重新选择并保存，然后重启应用。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await _service.save(
        NetworkProxySettings(
          mode: _mode,
          // Clear unused values rather than retaining accidentally pasted secrets.
          host: _mode == NetworkProxyMode.manual ? _host.text.trim() : '',
          port: _mode == NetworkProxyMode.manual
              ? int.parse(_port.text.trim())
              : 7890,
        ),
      );
      if (mounted) setState(() => _message = '已保存，完全退出并重新启动应用后生效。');
    } catch (_) {
      if (mounted) setState(() => _message = '保存失败，请重试；当前网络设置未改变。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('代理设置')),
    body: SafeArea(
      top: false,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text('默认遵循系统代理。设置适用于应用请求、图片、下载与播放器；修改后需完全重启应用。'),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<NetworkProxyMode>(
                    key: const Key('network-proxy-mode'),
                    initialValue: _mode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '连接方式',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: NetworkProxyMode.system,
                        child: Text('跟随系统（默认）'),
                      ),
                      DropdownMenuItem(
                        value: NetworkProxyMode.direct,
                        child: Text('直接连接'),
                      ),
                      DropdownMenuItem(
                        value: NetworkProxyMode.manual,
                        child: Text('手动 HTTP 代理'),
                      ),
                    ],
                    onChanged: _saving
                        ? null
                        : (mode) => setState(() {
                            _mode = mode!;
                            _message = null;
                          }),
                  ),
                  if (_mode == NetworkProxyMode.manual) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('network-proxy-host'),
                      controller: _host,
                      enabled: !_saving,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '代理服务器',
                        hintText: '127.0.0.1 或代理主机名',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          NetworkProxySettings.validateHost(value ?? ''),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('network-proxy-port'),
                      controller: _port,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          NetworkProxySettings.validatePort(value ?? ''),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    '仅支持无需认证的 HTTP 代理（HTTPS 网站使用 CONNECT）。不支持 SOCKS、代理账号密码或 HTTPS 代理服务器，不会关闭证书验证。',
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('save-network-proxy'),
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? '保存中…' : '保存，重启后生效'),
                  ),
                  const SizedBox(height: 12),
                  const ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('适用范围与平台限制'),
                    children: [
                      Text(
                        'Windows 使用当前用户代理与 PAC；Android 使用系统 ProxySelector；macOS / iOS 支持系统静态代理与绕过规则，暂不支持 PAC。Linux 需 GIO 代理后端（glib-networking/libproxy）；无后端时仅使用明确的代理环境变量，否则报错。系统无法解析的代理不会自动改为直连。',
                      ),
                      SizedBox(height: 12),
                      Text(
                        '桌面与 Apple 播放器仅在打开时解析音视频共同的首选代理。后续媒体重定向沿用该代理，不逐地址重新应用系统规则。音视频代理不一致或存在 no_proxy 环境变量且需要代理时，将提示失败。',
                      ),
                      SizedBox(height: 12),
                      Text(
                        'WebView 登录和外部浏览器仍由系统管理，不受应用手动或直连选项控制。VPN / TUN 路由不会被此设置关闭。代理地址仅保存在本机，不随设置导出。',
                      ),
                      SizedBox(height: 12),
                    ],
                  ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _message!,
                        key: const Key('network-proxy-message'),
                      ),
                    ),
                ],
              ),
            ),
    ),
  );
}
