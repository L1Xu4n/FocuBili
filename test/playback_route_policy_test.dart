import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/playback_line_preference.dart';
import 'package:focubili/services/playback_route_policy.dart';

/// 验证校园网双主线故障的选择策略和特殊签名地址边界，不访问真实 CDN。
void main() {
  const campus =
      'https://cn-jsnj-fx-02-01.bilivideo.com/upgcxcode/video?sign=a%2Fb';
  const mirror =
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?sign=a%2Fb';
  const pcdn = 'https://x.mcdn.bilivideo.cn/v1/resource/video?sign=a%2Fb';

  /// 智能模式使用已有镜像；备用模式仍保留主线且不改变签名。
  test('智能与备用优先均避开校园网主线并保留兜底', () {
    expect(PlaybackRoutePolicy.order([campus, mirror, mirror]), [
      mirror,
      campus,
    ]);
    expect(
      PlaybackRoutePolicy.order([
        campus,
        mirror,
      ], preference: PlaybackLinePreference.backup),
      [mirror, campus],
    );
    expect(
      PlaybackRoutePolicy.order([
        campus,
      ], preference: PlaybackLinePreference.backup),
      [campus],
    );
  });

  /// 用户可恢复接口原始顺序，PCDN 开关与主备偏好分别生效。
  test('主线优先且关闭避开 PCDN 时恢复原始顺序', () {
    expect(
      PlaybackRoutePolicy.order(
        [pcdn, mirror],
        preference: PlaybackLinePreference.primary,
        preferNonPcdn: false,
      ),
      [pcdn, mirror],
    );
    expect(
      PlaybackRoutePolicy.order([
        pcdn,
        mirror,
      ], preference: PlaybackLinePreference.primary),
      [mirror, pcdn],
    );
  });

  /// 特殊路径、os 标记不被误当镜像，纯 PCDN 不清空；Akamai 原始签名不改写。
  test('PCDN 和 Akamai 特殊地址只排序不改写', () {
    final disguised = '$mirror&os=mcdn';
    const akamai =
        'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/video?hdnts=a%2Fb';
    expect(PlaybackRoutePolicy.isPcdn(disguised), isTrue);
    expect(PlaybackRoutePolicy.isPcdn(campus), isFalse);
    expect(PlaybackRoutePolicy.order([pcdn, disguised]), [pcdn, disguised]);
    expect(PlaybackRoutePolicy.order([pcdn, akamai]), [akamai, pcdn]);
  });
}
