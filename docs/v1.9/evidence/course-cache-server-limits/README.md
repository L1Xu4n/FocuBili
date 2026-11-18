# 课堂缓存：按服务端期限，不另设 24 小时

基线 `8a97388`（#120）。相同测试在基线重现了三种结果：明确长期被截到 24 小时、已确认购买及完整媒体但没有期限字段时被拒绝、实际 5 天的截止被提前截到 24 小时。

## 实际规则

- 继续验证安全会话所属账号、购买记录、确切章节及完整可缓存媒体；试看、DRM、水印或明确禁止缓存仍不通过。B 站官方的 [DRM 体验课](https://www.bilibili.com/cheese/play/ep1241812) 同时显示「长期有效」和 DRM/试看，因此长期有效不是离线许可。
- 如果服务端给出有效的购买或离线截止，取已知较早日期；仅给出天数但拿不到该账号实际截止，或字段乱码、不相容，不当成无限期。已经确认的真实截止不会被后续省略日期或「长期有效」说明擦掉；需要新的明确服务端期限才能代替旧限期。
- 完整验证后，分别记录「明确长期」与「服务端未给截止」。两种都不额外设日期，也不表示官方承诺永久授权。没有已验证收据、未知格式或别的账号仍不能打开文件。断网时无法得知新的退款；一旦在线复核明确返回失权、到期或禁止缓存，立即撤销或收紧本地权限。
- CDN 地址的签名只影响下载/版本核验请求，不是本机播放权限的期限。普通视频离线入口、目录和格式不变。
- 旧收据保留原截止，只有联网验证后才改用新规则，不能因为新版本就升为长期。文件哈希和服务器媒体版本都相同时只复核不下载；测试记录两个 HEAD、零正文。损坏或无法确认相同版本时仍按安全路径处理。

## 实测与边界

公开匿名课堂样本中的 `user_status.payed/is_expired/expire_at/user_expiry_content`、元数据的 `expiry_day/expiry_info_content/show_watermark` 及章节可看状态只证实字段形状。例如未购样本也会返回 `expire_at=0` 与「长期有效」，不能从这些字段单独推断购买或缓存权限。

真实 Flutter 课堂列表和 PlayerPage 使用合成章节、受控时钟和方法通道替身；权限验证走正式 Dart 解析器。存储回归走真实临时目录和合成媒体，复核使用回环 HTTP；Windows guard 用可计数的媒体后端。没有登录真实付费账号、下载真实课程或打开受保护内容。这台宿主没有 Android Gradle/Kotlin 工具链，Android 只是验证 Flutter 发给原生的参数；新增 Kotlin 单测保留给 Android CI，未在此宿主或实机执行。

[列表截图：模拟核验两天后仍显示「离线播放」，不弹联网复核](course-cache-verified-no-deadline.png)。

```sh
flutter test -j1 --no-pub test/course_cache_access_test.dart test/course_cache_library_test.dart test/course_cache_recheck_test.dart test/course_cache_page_test.dart test/course_cache_windows_guard_test.dart test/native_playback_service_test.dart
```
