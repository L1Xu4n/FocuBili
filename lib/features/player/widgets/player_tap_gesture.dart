import 'dart:async';

import 'package:flutter/gestures.dart';

/// 只在视频画面内将触摸容差从默认 18 增到 24 逻辑像素。
const playerTouchGestureSettings = DeviceGestureSettings(touchSlop: 24);

/// 共用点击识别器处理单击和双击，让轻微位移容差与画面拖动阈值一致。
class PlayerTapGestureRecognizer extends TapGestureRecognizer {
  /// 使用 Flutter 的点击/拖动竞争规则，增加双击配对和单击延迟派发。
  PlayerTapGestureRecognizer({super.debugOwner}) {
    onTapUp = _handleTapUp;
    onTapCancel = _cancelPendingTap;
  }

  GestureTapCallback? onSingleTap;
  GestureTapDownCallback? onDoubleTapDown;
  GestureTapCallback? onDoubleTap;
  Timer? _singleTapTimer;
  Timer? _minimumTapTimer;
  TapDownDetails? _currentDown;
  TapUpDetails? _pendingTap;
  bool _completingDoubleTap = false;

  /// 在第二次按下时按系统双击间隔和落点距离配对；真实拖动仍参加手势竞争。
  @override
  void addAllowedPointer(PointerDownEvent event) {
    final pending = _pendingTap;
    _completingDoubleTap =
        pending != null &&
        _singleTapTimer?.isActive == true &&
        _minimumTapTimer?.isActive == false &&
        (event.position - pending.globalPosition).distance <= kDoubleTapSlop;
    if (_completingDoubleTap) {
      _singleTapTimer?.cancel();
    } else if (pending != null) {
      _flushSingleTap();
    }
    if (!_completingDoubleTap) {
      _minimumTapTimer?.cancel();
      _minimumTapTimer = Timer(kDoubleTapMinTime, () {});
    }
    _currentDown = TapDownDetails(
      globalPosition: event.position,
      localPosition: event.localPosition,
      kind: event.kind,
    );
    super.addAllowedPointer(event);
  }

  /// 双击成功只派发双击；第一击等待系统双击窗口结束后再派发单击。
  void _handleTapUp(TapUpDetails details) {
    if (_completingDoubleTap) {
      final down = _currentDown;
      _cancelPendingTap();
      if (down != null) onDoubleTapDown?.call(down);
      onDoubleTap?.call();
      return;
    }
    _pendingTap = details;
    _singleTapTimer = Timer(kDoubleTapTimeout, _flushSingleTap);
  }

  /// 确认只有一次点击时切换控制层，避免双击额外触发两次单击。
  void _flushSingleTap() {
    final pending = _pendingTap;
    _cancelPendingTap();
    if (pending != null) onSingleTap?.call();
  }

  /// 拖动、长按或系统取消赢得手势竞争后清理待派发点击。
  void _cancelPendingTap() {
    _singleTapTimer?.cancel();
    _minimumTapTimer?.cancel();
    _singleTapTimer = null;
    _minimumTapTimer = null;
    _pendingTap = null;
    _completingDoubleTap = false;
  }

  /// 即使拖动在点击按下回调之前胜出，也撤销正在配对的上一击。
  @override
  void rejectGesture(int pointer) {
    _cancelPendingTap();
    super.rejectGesture(pointer);
  }

  /// 系统取消触点时直接清理尚未确认的点击。
  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent) _cancelPendingTap();
    super.handleEvent(event);
  }

  /// 画面离开或锁定时取消点击计时，避免迟到的回调。
  @override
  void dispose() {
    _cancelPendingTap();
    super.dispose();
  }
}
