import '../../core/widgets/drag_selection_region.dart';
import '../../models/public_profile.dart';

/// 选中的是稳定 BV，不是视图位置。单次拖动相对本次起点重算，往回拖可以缩短范围。
class VideoListSelection {
  bool active = false;
  Set<String> ids = {};
  Set<String> _beforeDrag = {};
  void start([String? id]) {
    active = true;
    if (id != null) ids.add(id);
  }

  void end() {
    active = false;
    ids = {};
    _beforeDrag = {};
  }

  /// 投影变化只移除不再可见的身份，不能让旧手势的原始快照把它们还原。
  void keepVisible(Iterable<String> visible) {
    final valid = visible.toSet();
    ids.retainAll(valid);
    _beforeDrag.retainAll(valid);
  }

  void toggle(String id) {
    active = true;
    if (!ids.remove(id)) ids.add(id);
  }

  void range(DragSelectionUpdate update, List<CreatorVideo> items) {
    if (!active ||
        items.isEmpty ||
        update.anchor < 0 ||
        update.current < 0 ||
        update.anchor >= items.length ||
        update.current >= items.length) {
      return;
    }
    if (update.anchor == update.previous && update.previous == update.current) {
      _beforeDrag = {...ids};
    }
    final next = {..._beforeDrag},
        lo = update.anchor < update.current ? update.anchor : update.current,
        hi = update.anchor > update.current ? update.anchor : update.current;
    for (var i = lo; i <= hi; i++) {
      if (update.checked) {
        next.add(items[i].bvid);
      } else {
        next.remove(items[i].bvid);
      }
    }
    ids = next;
  }
}
