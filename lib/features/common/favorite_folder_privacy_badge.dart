import 'package:flutter/material.dart';

/// Overlay for an explicitly private Bilibili folder, including empty covers.
class FavoriteFolderPrivacyBadge extends StatelessWidget {
  const FavoriteFolderPrivacyBadge({super.key});

  static const _description = '私密收藏夹';

  @override
  Widget build(BuildContext context) => Semantics(
    label: _description,
    child: const Tooltip(
      message: _description,
      excludeFromSemantics: true,
      // Hover shows the description; touch long press still goes to the folder.
      triggerMode: TooltipTriggerMode.manual,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.all(Radius.circular(5)),
        ),
        child: Padding(
          padding: EdgeInsets.all(3),
          child: Icon(
            Icons.lock_outline_rounded,
            size: 12,
            color: Colors.white,
          ),
        ),
      ),
    ),
  );
}
