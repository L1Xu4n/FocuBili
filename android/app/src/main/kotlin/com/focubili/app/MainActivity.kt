package com.focubili.app

import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity

/** 承载 Flutter 界面并管理 Android 原生播放桥的 Activity 入口。 */
class MainActivity : FlutterActivity() {
    private var nativePlaybackController: NativePlaybackController? = null
    private var bilibiliCookieController: BilibiliCookieController? = null
    private var deviceStatusController: DeviceStatusController? = null

    /** Activity 创建时允许横屏内容延伸到刘海短边，确保视频按物理屏幕中心布局。 */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val attributes = window.attributes
            attributes.layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            } else {
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            window.attributes = attributes
        }
    }

    /** 注册 Flutter 与 Android 原生播放器之间的方法通道。 */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativePlaybackController = NativePlaybackController(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            renderer = flutterEngine.renderer,
        )
        bilibiliCookieController = BilibiliCookieController(
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        deviceStatusController = DeviceStatusController(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    /** App 回到前台时恢复此前主动播放的原生视频。 */
    override fun onResume() {
        super.onResume()
        nativePlaybackController?.onHostResume()
    }

    /** App 进入后台时暂停原生播放，避免后台继续出声和耗电。 */
    override fun onPause() {
        if (!isInPictureInPictureMode) {
            nativePlaybackController?.onHostPause()
        }
        super.onPause()
    }

    /** 系统进入或退出画中画时通知播放器隐藏或恢复 Flutter 控制层。 */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        nativePlaybackController?.onPictureInPictureModeChanged(isInPictureInPictureMode)
    }

    /** Activity 销毁时释放播放器、视频纹理和后台播放请求，避免资源泄漏。 */
    override fun onDestroy() {
        nativePlaybackController?.onHostDestroy()
        nativePlaybackController = null
        bilibiliCookieController?.dispose()
        bilibiliCookieController = null
        deviceStatusController?.dispose()
        deviceStatusController = null
        super.onDestroy()
    }
}
