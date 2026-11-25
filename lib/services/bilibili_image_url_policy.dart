/// 定义全应用按展示用途划分的四档受控 B 站图片 CDN 缩放规格。
///
/// 保持各业务卡片原有裁切比例，避免跨比例裁切造成画面变形，同时把原图流量
/// 统一收敛为 WebP 缩略图。
enum BilibiliImageVariant {
  /// 16:10 封面（如搜索结果、视频详情与本地列表等沿用 16:10 的卡片）。
  cover16x10('@320w_200h_1c.webp'),

  /// 16:9 封面（如 UP 主投稿、收藏夹、订阅合集与课堂封面）。
  cover16x9('@480w_270h_1c.webp'),

  /// 视频章节预览小图。
  chapter('@320w_180h_1c.webp'),

  /// 用户/UP 主头像与关注分组头像。
  avatar('@160w_160h_1c.webp');

  const BilibiliImageVariant(this.suffix);

  final String suffix;
}

/// 集中管理可信 B 站图片主机（`hdslb.com` / `biliimg.com`）的缩放和不可变性判定。
abstract final class BilibiliImageUrlPolicy {
  static const Set<String> _transformableExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };

  /// 内容寻址的 B 站投稿封面通常采用 32 位及以上十六进制摘要文件名。
  static final RegExp _contentHashedArchivePath = RegExp(
    r'^/bfs/archive/[a-f0-9]{32,}\.(?:jpg|jpeg|png|webp)(?:@[^/?#]+)?$',
    caseSensitive: false,
  );

  /// 公开视频雪碧图（videoshot）精确不可变路径。
  static final RegExp _videoshotAtlasPath = RegExp(
    r'^/videoshotpvhdboss/\d+_[a-z0-9]+-\d+\.jpg(?:@[^/?#]+)?$',
    caseSensitive: false,
  );

  /// 判断主机是否为可信的 B 站图片 CDN 域（按域名标签精确匹配）。
  static bool isTrustedImageHost(String host) {
    final String normalized = host.trim().toLowerCase();
    return normalized == 'hdslb.com' ||
        normalized.endsWith('.hdslb.com') ||
        normalized == 'biliimg.com' ||
        normalized.endsWith('.biliimg.com');
  }

  /// 在展示/请求边界按 [variant] 派生 B 站 CDN WebP 缩放地址。
  ///
  /// 仅当满足以下全部条件时追加缩放后缀，否则原样返回 [rawUrl]：
  /// 1. 协议为 `http`、`https` 或 `//` 协议相对地址；
  /// 2. 主机匹配可信 `hdslb.com` / `biliimg.com` 域名标签；
  /// 3. 不含 `userinfo`、非标准端口、查询串（避免破坏签名 URL）或 fragment；
  /// 4. 路径非空、尚未包含 `@` 变换后缀，且扩展名为 `.jpg/.jpeg/.png/.webp`（跳过 `.gif`）。
  static String resolve(String rawUrl, {BilibiliImageVariant? variant}) {
    if (variant == null) {
      return rawUrl;
    }
    final String trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return rawUrl;
    }
    final String candidate = trimmed.startsWith('//')
        ? 'https:$trimmed'
        : trimmed;
    final Uri? uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        !isTrustedImageHost(uri.host)) {
      return rawUrl;
    }
    final String path = uri.path;
    if (path.isEmpty || path.contains('@')) {
      return rawUrl;
    }
    final int dotIndex = path.lastIndexOf('.');
    if (dotIndex < 0) {
      return rawUrl;
    }
    final String extension = path.substring(dotIndex).toLowerCase();
    if (!_transformableExtensions.contains(extension)) {
      return rawUrl;
    }
    return uri
        .replace(scheme: 'https', path: '$path${variant.suffix}')
        .toString();
  }

  /// 仅当 URL 匹配已证实不可变的内容寻址路径时返回 true，供缓存层在 CDN 明确返回
  /// 较长 `max-age` 时放宽 24 小时钳制（最长仍受缓存层硬上限与 CDN 响应头约束）。
  static bool isProvenImmutableContentUrl(Uri uri) {
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        !isTrustedImageHost(uri.host)) {
      return false;
    }
    final String host = uri.host.toLowerCase();
    if (host == 'bimp.hdslb.com' && _videoshotAtlasPath.hasMatch(uri.path)) {
      return true;
    }
    return _contentHashedArchivePath.hasMatch(uri.path);
  }
}
