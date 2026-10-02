import 'package:flutter/services.dart';

/// 保存公开的 WebView 内核信息，不包含网页、Cookie 或设备标识符。
class WebViewEnvironment {
  /// 创建原生读取结果；未知字段保持为空，避免把推测显示成检测结果。
  const WebViewEnvironment({
    this.packageName = '',
    this.version = '',
    this.manufacturer = '',
    this.model = '',
    this.apiLevel = 0,
    this.providerAvailable,
    this.message = '',
  });

  final String packageName;
  final String version;
  final String manufacturer;
  final String model;
  final int apiLevel;
  final bool? providerAvailable;
  final String message;

  /// 读取平台返回的固定字段，不读取 UA、网址或会话内容。
  factory WebViewEnvironment.fromMap(Map<Object?, Object?> values) {
    return WebViewEnvironment(
      packageName: values['packageName'] as String? ?? '',
      version: values['version'] as String? ?? '',
      manufacturer: values['manufacturer'] as String? ?? '',
      model: values['model'] as String? ?? '',
      apiLevel: (values['apiLevel'] as num?)?.toInt() ?? 0,
      providerAvailable: values['providerAvailable'] as bool?,
      message: values['message'] as String? ?? '',
    );
  }

  /// 为旧华为/荣耀的 Android 10/11 内核优先启用原生视图合成兼容模式。
  bool get prefersHybridComposition {
    final vendor = manufacturer.toLowerCase();
    return (vendor.contains('huawei') || vendor.contains('honor')) &&
        apiLevel >= 29 &&
        apiLevel <= 30;
  }

  /// 明确区分找到内核、没有内核和读取失败三个状态。
  String get statusLabel => switch (providerAvailable) {
    true => '已检测到内核',
    false => '未检测到可用内核',
    null => '暂时无法读取',
  };

  /// 说明登录页默认采用的渲染方式，便于复现设备兼容问题。
  String get compositionLabel =>
      prefersHybridComposition ? '兼容模式（原生视图合成）' : '默认模式（纹理合成）';

  /// 生成可直接附加到问题诊断中的公开内核信息。
  String toDiagnosticText() =>
      'WebView 信息：\n'
      '状态：$statusLabel\n'
      '内核包名：${packageName.isEmpty ? '未知' : packageName}\n'
      '内核版本：${version.isEmpty ? '未知' : version}\n'
      '登录默认渲染：$compositionLabel'
      '${message.isEmpty ? '' : '\n说明：$message'}';
}

/// 只查询系统选定的 WebView 包，不创建隐藏 WebView 或加载网页。
class WebViewEnvironmentService {
  /// 创建可注入方法通道的公开环境查询服务。
  const WebViewEnvironmentService({
    MethodChannel channel = const MethodChannel(
      'com.focubili.app/device_status',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// 限时读取内核信息；通道或内核不可用时返回明确的未知结果。
  Future<WebViewEnvironment> load() async {
    try {
      final values = await _channel
          .invokeMapMethod<Object?, Object?>('getWebViewInfo')
          .timeout(const Duration(seconds: 5));
      return values == null
          ? const WebViewEnvironment(message: '系统未返回 WebView 信息。')
          : WebViewEnvironment.fromMap(values);
    } catch (_) {
      return const WebViewEnvironment(message: '无法读取系统 WebView 信息，请稍后重试。');
    }
  }
}
