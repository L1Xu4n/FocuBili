import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/profile/cache_management_page.dart';
import 'package:focubili/services/media_cache_service.dart';

/// 用内存状态替代 Android 原生通道，使缓存管理页面能够稳定地进行 Widget 测试。
class _FakeMediaCacheService implements MediaCacheService {
  /// 创建带初始缓存快照的假服务。
  _FakeMediaCacheService(this.status);

  MediaCacheStatus status;
  int? requestedCapacity;
  bool clearRequested = false;

  /// 返回当前内存中的缓存快照。
  @override
  Future<MediaCacheStatus> loadStatus() async => status;

  /// 记录页面选择的容量并模拟 Android 返回更新后的缓存状态。
  @override
  Future<MediaCacheStatus> setCapacityBytes(int capacityBytes) async {
    requestedCapacity = capacityBytes;
    status = MediaCacheStatus(
      usedBytes: status.usedBytes,
      capacityBytes: capacityBytes,
      isPlaybackActive: status.isPlaybackActive,
    );
    return status;
  }

  /// 记录清空请求并把模拟缓存用量归零。
  @override
  Future<MediaCacheStatus> clearCache() async {
    clearRequested = true;
    status = MediaCacheStatus(
      usedBytes: 0,
      capacityBytes: status.capacityBytes,
      isPlaybackActive: status.isPlaybackActive,
    );
    return status;
  }
}

/// 为页面创建带 Material 主题和独立缓存服务的测试宿主。
Widget _buildTestApp(MediaCacheService service) {
  return MaterialApp(home: CacheManagementPage(service: service));
}

/// 验证缓存管理页面的占用、容量和播放保护行为。
void main() {
  /// 验证页面显示原生缓存快照和“非离线下载”的产品边界。
  testWidgets('显示缓存用量和边播边缓存说明', (WidgetTester tester) async {
    final _FakeMediaCacheService service = _FakeMediaCacheService(
      const MediaCacheStatus(
        usedBytes: 64 * 1024 * 1024,
        capacityBytes: defaultMediaCacheBytes,
        isPlaybackActive: false,
      ),
    );

    await tester.pumpWidget(_buildTestApp(service));
    await tester.pumpAndSettle();

    expect(find.text('64.0 MB / 512.0 MB'), findsOneWidget);
    expect(find.textContaining('不是离线下载'), findsOneWidget);
    expect(find.text('清空已缓存视频'), findsOneWidget);
  });

  /// 验证用户切换容量后页面使用服务返回的最新配置。
  testWidgets('切换缓存上限会调用服务并刷新页面', (WidgetTester tester) async {
    final _FakeMediaCacheService service = _FakeMediaCacheService(
      const MediaCacheStatus(
        usedBytes: 0,
        capacityBytes: defaultMediaCacheBytes,
        isPlaybackActive: false,
      ),
    );

    await tester.pumpWidget(_buildTestApp(service));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.0 GB').last);
    await tester.pumpAndSettle();

    expect(service.requestedCapacity, 1024 * 1024 * 1024);
    expect(find.text('容量上限：1.0 GB'), findsOneWidget);
  });

  /// 验证确认清空后会调用服务，并使用服务返回的零用量刷新摘要。
  testWidgets('确认清空会清除缓存并刷新用量', (WidgetTester tester) async {
    final _FakeMediaCacheService service = _FakeMediaCacheService(
      const MediaCacheStatus(
        usedBytes: 32 * 1024 * 1024,
        capacityBytes: defaultMediaCacheBytes,
        isPlaybackActive: false,
      ),
    );

    await tester.pumpWidget(_buildTestApp(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空已缓存视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清空'));
    await tester.pumpAndSettle();

    expect(service.clearRequested, isTrue);
    expect(find.text('0 B / 512.0 MB'), findsOneWidget);
  });

  /// 验证播放器仍活跃时容量选择和清空按钮都会被禁用。
  testWidgets('播放中禁用缓存清理和容量设置', (WidgetTester tester) async {
    final _FakeMediaCacheService service = _FakeMediaCacheService(
      const MediaCacheStatus(
        usedBytes: 32 * 1024 * 1024,
        capacityBytes: defaultMediaCacheBytes,
        isPlaybackActive: true,
      ),
    );

    await tester.pumpWidget(_buildTestApp(service));
    await tester.pumpAndSettle();

    final DropdownButtonFormField<int> picker = tester.widget(
      find.byType(DropdownButtonFormField<int>),
    );
    expect(find.text('播放中暂不能管理缓存'), findsOneWidget);
    expect(find.text('清空已缓存视频'), findsOneWidget);
    expect(picker.onChanged, isNull);
  });
}
