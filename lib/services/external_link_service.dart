import 'package:url_launcher/url_launcher.dart';

/// 可注入的外链启动函数；测试可以记录地址而不真正打开系统浏览器。
typedef ExternalLinkLauncher = Future<bool> Function(Uri uri);

/// 只把已经过页面风险确认的 HTTP(S) 地址交给设备默认浏览器。
Future<bool> launchExternalLink(Uri uri) async {
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
