# FocuBili v1.3.1 发布说明

状态：正式发布

版本号：`1.3.1+14`

更新日期：2026 年 8 月 9 日

<!-- focubili-update-summary:start -->
- 修复了在 QQ 内链接无法被跳转的问题。
<!-- focubili-update-summary:end -->

## 问题原因

- QQ 分享使用 `bilibili://video/{AV号}`，并在 `h5awaken` 中携带一段很长的 Base64 唤醒数据。
- 旧解析会在整段原始查询文本里搜索 BV 形状；Base64 文本可能随机包含符合格式的字符，错误结果会抢在真实 AV 号前被使用。
- 焦点哔哩随后拿错误 BV 请求视频详情，因此 B 站接口返回请求错误 `-400`。

## 修复方式

- 只从视频路径和明确的 `bvid`、`aid`、`avid` 查询字段读取编号，不再扫描整段不透明查询文本。
- 优先把 Scheme 路径中的超大 AV 号转换为真实 BV；用户提供的 `117054938090233` 会得到 `BV1EWu86rEFg`。
- 外层编号缺失或不可用时，安全解码 `h5awaken`，再从官方 `open_app_url` 内容恢复标准 BV 号。
- Base64 损坏或内容不含视频编号时安全拒绝，不会崩溃或发出错误详情请求。

## 当前验证

- 用户已在 Android 真机通过原始 QQ 分享链接复测，能够正确跳转，不再出现请求错误 `-400`。
- 深链解析定向静态分析：通过，0 个问题。
- 深链解析测试：6 项全部通过。
- `flutter analyze --no-pub`：通过，0 个问题。
- `flutter test --no-pub`：311 项全部通过。
- Android Debug APK：构建成功；包内确认 `versionName 1.3.1`、`versionCode 14`、最低 Android 7.0（API 24）。
- MuMu 平板模拟器：覆盖安装成功，系统确认安装版本为 `1.3.1 (14)`；应用已启动且日志无致命异常。
- Debug APK SHA-256：`65D7CD030CCA198DEC41B00754597D59E4EA0EC0369124DC04E870DDE913CDCD`。

## Release APK

- 文件：`FocuBili-v1.3.1-release.apk`
- 文件大小：`66,693,046` 字节。
- SHA-256：`51CA3E4854F788A8BED211D34C0B158E4EAB145A642DFF770B6E9C574A71EC6C`
- 包信息：`versionName 1.3.1`、`versionCode 14`、最低 API 24、目标 API 36。
- 校验：zipalign 通过，APK Signature Scheme v2 签名验证通过。
- MuMu 平板：正式 APK 覆盖安装成功，系统确认 `1.3.1 (14)` 并成功启动应用进程。
- 签名：当前仍使用 Android Debug 证书进行测试分发，正式应用商店发布前需要配置独立 Release 密钥。
