import 'dart:convert';

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

  /// QQ 的超大 AV 号必须转换成真实 BV，Base64 原文中的随机 BV 形状不能抢先覆盖。
  test('解析 QQ 分享 Scheme 的超大 AV 号并忽略不透明参数误匹配', () {
    final BilibiliVideoDeepLinkTarget? target = BilibiliDeepLinkParser.parse(
      'bilibili://video/117054938090233?'
      'from_spmid=main.h5.share.6g12lqp.8g9x97j9dxseqgeymskqyaqt&'
      'h5awaken=BVabcdefghijOpaqueBase64Text&page=0&trackid=',
    );

    expect(target?.bvid, 'BV1EWu86rEFg');
    expect(target?.partPageNumber, 1);
  });

  /// 外层编号缺失时，从 QQ 解码后的 open_app_url 恢复 BV，损坏 Base64 则安全拒绝。
  test('从 QQ h5awaken 恢复标准 BV 链接', () {
    final String awakenPayload = base64.encode(
      utf8.encode(
        'open_app_from_type=h5&'
        'open_app_url=https%3A%2F%2Fm.bilibili.com%2Fvideo%2F'
        'BV1EWu86rEFg%3Fp%3D1&item_id=%7B%22avid%22%3A117054938090233%7D',
      ),
    );
    final BilibiliVideoDeepLinkTarget? target = BilibiliDeepLinkParser.parse(
      'bilibili://video/not-numeric?h5awaken=$awakenPayload',
    );

    expect(target?.bvid, 'BV1EWu86rEFg');
    expect(
      BilibiliDeepLinkParser.parse(
        'bilibili://video/not-numeric?h5awaken=not-valid-base64!',
      ),
      isNull,
    );
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
