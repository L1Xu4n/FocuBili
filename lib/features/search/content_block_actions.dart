import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/content_blocklist_service.dart';

/// Shared immediate block + undo behavior for search and player menus.
class ContentBlockActions {
  static final _channels = Expando<_BlockFeedbackChannel>();

  static Future<void> video(
    BuildContext context, {
    required String bvid,
    required String title,
  }) => _apply(
    context,
    '已屏蔽该视频',
    () => const ContentBlocklistService().blockVideoWithUndo(bvid, title),
  );

  static Future<void> creator(
    BuildContext context, {
    required int mid,
    required String name,
  }) => _apply(
    context,
    '已屏蔽该 UP 主',
    () => const ContentBlocklistService().blockCreatorWithUndo(mid, name),
  );

  static Future<void> _apply(
    BuildContext context,
    String message,
    Future<ContentBlockUndo?> Function() save,
  ) async {
    final route = ModalRoute.of(context);
    ContentBlockUndo? undo;
    try {
      undo = await save();
      if (!context.mounted || route?.isCurrent == false) {
        undo?.discard();
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      final channel = _channels[messenger] ??= _BlockFeedbackChannel(messenger);
      channel.offer(
        _BlockNotice(
          context,
          route,
          undo == null ? '已在黑名单中，可在管理页面取消屏蔽。' : '$message，可在黑名单中取消。',
          undo,
        ),
      );
    } catch (_) {
      undo?.discard();
      if (context.mounted && route?.isCurrent != false) {
        _showError(context, '黑名单保存失败，请重试。');
      }
    }
  }

  static void _showError(BuildContext context, String message) =>
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
}

class _BlockNotice {
  _BlockNotice(this.context, this.route, this.message, this.undo);

  final BuildContext context;
  final ModalRoute<dynamic>? route;
  final String message;
  final ContentBlockUndo? undo;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? controller;
  bool visible = false;
  bool closing = false;

  bool get isCurrent => context.mounted && route?.isCurrent != false;
}

/// Keeps one reminder and at most one replacement, without ever dismissing
/// another feature's message (or creating a second timer outside Flutter).
class _BlockFeedbackChannel {
  _BlockFeedbackChannel(this._messenger);

  static const _normalDuration = Duration(seconds: 4);
  static const _accessibleInfoDuration = Duration(seconds: 8);
  final ScaffoldMessengerState _messenger;
  _BlockNotice? _shown;
  _BlockNotice? _next;

  void offer(_BlockNotice notice) {
    final shown = _shown;
    if (shown == null) {
      _show(notice);
      return;
    }
    _next?.undo?.discard();
    _next = notice;
    // A framework close may have completed in this event before its Future
    // listener runs. Recheck ownership after that close is delivered.
    scheduleMicrotask(() => _dismissIfOwned(shown));
  }

  void _show(_BlockNotice notice) {
    if (!_messenger.mounted || !notice.isCurrent) {
      notice.undo?.discard();
      return;
    }
    final accessible = MediaQuery.accessibleNavigationOf(notice.context);
    final undo = notice.undo;
    final controller = _messenger.showSnackBar(
      SnackBar(
        // With an action, null defaults to a persistent SnackBar.
        persist: accessible && undo != null,
        duration: accessible ? _accessibleInfoDuration : _normalDuration,
        showCloseIcon: true,
        content: Builder(
          builder: (context) {
            final renderRoute = ModalRoute.of(context);
            // The messenger can carry a SnackBar to a different route.
            // Keep the confirmation and undo on the page that issued them.
            if (notice.route != null &&
                renderRoute != notice.route &&
                !notice.isCurrent) {
              scheduleMicrotask(() => _dismissIfOwned(notice));
            }
            return Text(notice.message);
          },
        ),
        action: undo == null
            ? null
            : SnackBarAction(
                label: '撤销',
                onPressed: () async {
                  if (!notice.isCurrent || notice.closing || _next != null) {
                    return;
                  }
                  try {
                    await undo.apply();
                  } catch (_) {
                    if (notice.isCurrent) {
                      ContentBlockActions._showError(
                        notice.context,
                        '撤销屏蔽失败，请重试。',
                      );
                    }
                  }
                },
              ),
        onVisible: () {
          notice.visible = true;
          scheduleMicrotask(() {
            if (_next != null || !notice.isCurrent) {
              _dismissIfOwned(notice);
            }
          });
        },
      ),
    );
    notice.controller = controller;
    _shown = notice;
    unawaited(
      controller.closed.then((_) {
        notice.undo?.discard();
        if (!identical(_shown, notice)) return;
        _shown = null;
        final next = _next;
        _next = null;
        if (next != null) _show(next);
      }),
    );
  }

  void _dismissIfOwned(_BlockNotice notice) {
    if (!_messenger.mounted ||
        !identical(_shown, notice) ||
        !notice.visible ||
        notice.closing) {
      return;
    }
    notice.closing = true;
    notice.controller?.close();
  }
}
