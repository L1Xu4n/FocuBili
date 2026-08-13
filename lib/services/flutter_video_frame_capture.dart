import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 从 Flutter 已经绘制的视频画面中安全读取 PNG，避免再次调用播放器原生截图接口。
class FlutterVideoFrameCapture {
  RenderRepaintBoundary? _activeBoundary;

  /// 为视频画面增加独立重绘边界；边界随当前组件树挂载，不使用会跨父节点迁移的 GlobalKey。
  Widget wrap(Widget child) {
    return _FrameCaptureBoundary(capture: this, child: child);
  }

  /// 把当前重绘边界编码为 PNG；画面尚未挂载、尚未绘制或编码失败时返回空值。
  Future<Uint8List?> capturePngBytes({double pixelRatio = 1}) async {
    if (!pixelRatio.isFinite || pixelRatio <= 0) {
      return null;
    }
    RenderRepaintBoundary? boundary = _findBoundary();
    if (boundary == null) {
      return null;
    }
    if (boundary.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
      boundary = _findBoundary();
      if (boundary == null || boundary.debugNeedsPaint) {
        return null;
      }
    }
    ui.Image? image;
    try {
      image = await boundary.toImage(pixelRatio: pixelRatio);
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on Object {
      return null;
    } finally {
      image?.dispose();
    }
  }

  /// 查找当前仍挂载的重绘边界，页面切换或销毁期间安全返回空值。
  RenderRepaintBoundary? _findBoundary() {
    final RenderRepaintBoundary? boundary = _activeBoundary;
    return (boundary?.attached ?? false) ? boundary : null;
  }

  /// 登记刚挂载的当前画面；布局切换短暂重叠时以最后挂载的边界为准。
  void _registerBoundary(RenderRepaintBoundary boundary) {
    _activeBoundary = boundary;
  }

  /// 只注销同一个旧边界，避免旧树晚一步卸载时清掉已经挂载的新画面。
  void _unregisterBoundary(RenderRepaintBoundary boundary) {
    if (identical(_activeBoundary, boundary)) {
      _activeBoundary = null;
    }
  }
}

/// 创建可向取帧器登记自身的重绘边界，让 RenderObject 生命周期替代 GlobalKey 查找。
class _FrameCaptureBoundary extends SingleChildRenderObjectWidget {
  /// 保存当前取帧器并把视频画面作为唯一子节点。
  const _FrameCaptureBoundary({required this.capture, required super.child});

  final FlutterVideoFrameCapture capture;

  /// 创建真正负责隔离绘制与导出图片的渲染对象。
  @override
  RenderRepaintBoundary createRenderObject(BuildContext context) {
    return _RegisteredRepaintBoundary(capture: capture);
  }

  /// 父组件替换取帧器时同步登记目标，避免渲染对象继续指向旧服务。
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RegisteredRepaintBoundary renderObject,
  ) {
    renderObject.capture = capture;
  }
}

/// 在挂载和卸载时登记当前有效画面的重绘边界。
class _RegisteredRepaintBoundary extends RenderRepaintBoundary {
  /// 创建属于指定取帧器的渲染边界。
  _RegisteredRepaintBoundary({required FlutterVideoFrameCapture capture})
    : _capture = capture;

  FlutterVideoFrameCapture _capture;

  /// 返回当前接收 PNG 取帧请求的服务。
  FlutterVideoFrameCapture get capture => _capture;

  /// 切换服务时先撤销旧登记，再把已挂载边界交给新服务。
  set capture(FlutterVideoFrameCapture value) {
    if (identical(_capture, value)) {
      return;
    }
    if (attached) {
      _capture._unregisterBoundary(this);
    }
    _capture = value;
    if (attached) {
      _capture._registerBoundary(this);
    }
  }

  /// 渲染对象进入当前组件树后登记为可截图画面。
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _capture._registerBoundary(this);
  }

  /// 渲染对象离开组件树前撤销登记，异步取帧会安全返回空值。
  @override
  void detach() {
    _capture._unregisterBoundary(this);
    super.detach();
  }
}
