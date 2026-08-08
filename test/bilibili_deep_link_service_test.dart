import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/core/utils/bilibili_id_converter.dart';
import 'package:focubili/services/bilibili_deep_link_service.dart';

/// 验证 QQ、B站网页和 Android Scheme 传入的视频链接可以稳定转换成播放器目标。
void main() {
  /// AV/BV 公开编号算法必须与已知 B站视频编号一致。
  test('AV 号转换为已知 BV 号', () {
    expect(BilibiliIdConverter.avToBv(170001), 'BV17x411w7KC');
    expect(BilibiliIdConverter.avToBv(0), isNull);
  });

  /// 官方网页常用的数字 AV Scheme 会转换 BV，并保留 CID、分P和毫秒进度。
  test('解析 bilibili 视频 Scheme 的数字 AV 号和播放参数', () {
    final BilibiliVideoDeepLinkTarget? target = BilibiliDeepLinkParser.parse(
      'bilibili://video/170001?cid=279786&page=0&dm_progress=12500',
    );

    expect(target?.bvid, 'BV17x411w7KC');
    expect(target?.partCid, 279786);
    expect(target?.partPageNumber, 1);
    expect(target?.initialPosition, const Duration(milliseconds: 12500));
  });

  /// 标准 B站视频网页会提取 BV、网页分P和秒数时间点。
  test('解析标准 B站视频网页', () {
    final BilibiliVideoDeepLinkTarget? target = BilibiliDeepLinkParser.parse(
      'https://www.bilibili.com/video/BV1GJ411x7h7/?p=2&t=9.5',
    );

    expect(target?.bvid, 'BV1GJ411x7h7');
    expect(target?.partPageNumber, 2);
    expect(target?.initialPosition, const Duration(milliseconds: 9500));
  });

  /// 非视频 Scheme、其他网站和损坏编号不能触发应用内导航。
  test('拒绝非视频或非 B站链接', () {
    expect(BilibiliDeepLinkParser.parse('bilibili://space/123'), isNull);
    expect(
      BilibiliDeepLinkParser.parse('https://example.com/video/BV1GJ411x7h7'),
      isNull,
    );
    expect(BilibiliDeepLinkParser.parse('bilibili://video/not-valid'), isNull);
  });
}
