import 'image_resource_cache.dart';
import 'subscription_service.dart';

/// 隔离存放在缓存索引和订阅事务库中的偏好，禁止迁移用户内容。
abstract interface class SettingsRuntimeAdapter {
  /// 读取允许迁移的运行期偏好，不返回源列表、视频或缓存内容。
  Future<Map<String, Object>> readSettings();

  /// 合并指定偏好；null 表示恢复该项默认值，未列出项保持原值。
  Future<void> writeSettings(Map<String, Object?> values);
}

/// 通过各服务现有公开事务入口写设置，保留去重、订阅源和缓存文件保护。
class DeviceSettingsRuntimeAdapter implements SettingsRuntimeAdapter {
  /// 创建原生设置适配器，测试可注入合成订阅和临时缓存。
  const DeviceSettingsRuntimeAdapter({this.subscriptions, this.imageCache});

  static const enabledKey = 'subscriptions.enabled';
  static const notificationsKey = 'subscriptions.notifications_enabled';
  static const backgroundKey = 'subscriptions.background_refresh_enabled';
  static const imageCapacityKey = 'resource_cache.image_capacity_bytes';
  static const subscriptionKeys = {enabledKey, notificationsKey, backgroundKey};
  static const keys = {...subscriptionKeys, imageCapacityKey};
  final SubscriptionService? subscriptions;
  final ImageResourceCache? imageCache;

  /// 获取当前应用唯一的订阅服务，不直接读取或覆盖其数据库快照。
  SubscriptionService get _subscriptions =>
      subscriptions ?? SubscriptionService.instance;

  /// 获取共享图片缓存，避免创建另一个不受账号生命周期管理的缓存实例。
  ImageResourceCache get _images => imageCache ?? ImageResourceCache.instance;

  /// 确认订阅状态可读；读取失败时保留原数据并停止迁移。
  Future<void> _prepareSubscriptions() async {
    await _subscriptions.initialize();
    if (_subscriptions.storageError != null) throw StateError('订阅设置暂不可读');
  }

  /// 导出三个订阅开关和图片缓存容量，其他订阅与缓存字段留在原设备。
  @override
  Future<Map<String, Object>> readSettings() async {
    await _prepareSubscriptions();
    final imageUsage = await _images.status();
    return {
      enabledKey: _subscriptions.enabled,
      notificationsKey: _subscriptions.notificationsEnabled,
      backgroundKey: _subscriptions.backgroundRefreshEnabled,
      imageCapacityKey: imageUsage.capacityBytes,
    };
  }

  /// 先关闭总开关再改子开关；开启总开关放到最后，避免导入途中启动检查。
  @override
  Future<void> writeSettings(Map<String, Object?> values) async {
    if (values.keys.any(subscriptionKeys.contains)) {
      await _prepareSubscriptions();
      final enabled = values.containsKey(enabledKey)
          ? values[enabledKey] as bool? ?? false
          : _subscriptions.enabled;
      if (!enabled && _subscriptions.enabled) {
        await _subscriptions.setEnabled(false);
      }
      if (values.containsKey(notificationsKey)) {
        final value = values[notificationsKey] as bool? ?? false;
        if (value != _subscriptions.notificationsEnabled) {
          await _subscriptions.setNotificationsEnabled(value);
        }
      }
      if (values.containsKey(backgroundKey)) {
        final value = values[backgroundKey] as bool? ?? false;
        if (value != _subscriptions.backgroundRefreshEnabled) {
          await _subscriptions.setBackgroundRefreshEnabled(value);
        }
      }
      if (enabled && !_subscriptions.enabled) {
        await _subscriptions.setEnabled(true);
      }
    }
    if (values.containsKey(imageCapacityKey)) {
      await _images.setCapacity(
        values[imageCapacityKey] as int? ?? _images.defaultCapacity,
      );
    }
  }
}
