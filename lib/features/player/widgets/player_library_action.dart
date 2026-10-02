import 'package:flutter/material.dart';

/// A compact icon-over-label action shared by the four player library controls.
class PlayerLibraryAction extends StatelessWidget {
  /// Keeps action dimensions stable across loading, selection and label changes.
  const PlayerLibraryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onPressed,
    this.busy = false,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;
  final bool selected;

  /// Builds a flat, accessible action without decorative nested cards.
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: TextButton(
      onPressed: busy ? null : onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        foregroundColor: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 22,
            child: busy
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Icon(icon, size: 22),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
