import 'package:flutter/material.dart';
import '../../models/content_blocklist.dart';
import '../../services/content_blocklist_service.dart';

/// Shared immediate block + undo behavior for search and player menus.
class ContentBlockActions {
  static Future<void> video(
    BuildContext context, {
    required String bvid,
    required String title,
  }) => _apply(
    context,
    '已屏蔽该视频',
    (list) => list.videos.containsKey(bvid),
    () => const ContentBlocklistService().blockVideo(bvid, title),
    () => const ContentBlocklistService().unblockVideo(bvid),
  );

  static Future<void> creator(
    BuildContext context, {
    required int mid,
    required String name,
  }) => _apply(
    context,
    '已屏蔽该 UP 主',
    (list) => list.creators.containsKey(mid),
    () => const ContentBlocklistService().blockCreator(mid, name),
    () => const ContentBlocklistService().unblockCreator(mid),
  );

  static Future<void> _apply(
    BuildContext context,
    String message,
    bool Function(ContentBlocklist) alreadyBlocked,
    Future<void> Function() save,
    Future<void> Function() undo,
  ) async {
    try {
      final list = await const ContentBlocklistService().load();
      if (!context.mounted) return;
      if (alreadyBlocked(list)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('已在黑名单中，可在管理页面取消屏蔽。')));
        return;
      }
      await save();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('$message，可在黑名单中取消。'),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () async {
                try {
                  await undo();
                } catch (_) {
                  if (context.mounted) _error(context);
                }
              },
            ),
          ),
        );
    } catch (_) {
      if (context.mounted) _error(context);
    }
  }

  static void _error(BuildContext context) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('黑名单保存失败，请重试。')));
}
