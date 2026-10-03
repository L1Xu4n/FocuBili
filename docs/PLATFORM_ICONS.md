# 平台图标与深色外观

本次只接入系统图标外观，不实现随应用内自定义主题色切换备用图标。

- Android 传统启动图标提供圆角浅色及 `night` 深色密度资源。Android 8+ 使用前景/背景分层的自适应图标，最终外形由桌面决定，不能强迫所有启动器显示同一圆角。夜间资源是否即时更新取决于桌面配置与缓存。
- Android 13+ 提供 monochrome 图层。用户启用“主题图标”且桌面支持时，由系统根据壁纸和主题染色；这与彩色深色版本不同。
- iOS/iPadOS 18+ 的 AppIcon 提供 dark appearance，用户可在桌面选择浅色、深色或自动。输入使用完整方形画布，由系统统一裁切，避免重复圆角。
- macOS 26+ 使用 FocuBiliIcon.icon 的 light/dark 源，需 Xcode 26.3 构建。Xcode 生成旧系统使用的静态兼容图标；旧系统不保证能切换独立深色图标。仓库保留传统 AppIcon 图集，但当前目标选择 Icon Composer 图标。
- 应用标识与签名配置不变；切换系统图标外观不产生第二个应用、不改变数据容器。

## 资源与检查

`assets/icon/source/` 保存 PNG 设计源。`bash tool/build_platform_icons.sh` 用 ImageMagick 编译各平台尺寸；修改后执行 `python3 tool/check_platform_icons.py`。

Apple CI 使用 Xcode 26.3，编译设备未签名包、模拟器与 macOS 包并运行现有原生播放检查。Android CI 编译 debug APK 并运行原有测试。资源检查覆盖密度、night、monochrome 和 Apple appearance 引用；编译通过不等于所有第三方 Android 桌面的缓存/主题行为已实测。

来源：
- https://developer.android.com/develop/ui/views/launch/icon_design_adaptive
- https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
