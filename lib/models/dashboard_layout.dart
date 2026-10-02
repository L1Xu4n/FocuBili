import 'package:flutter/material.dart';

/// 页面登记的卡片，身份永远使用稳定编号而非标题或下标。
class DashboardCardDefinition {
  /// 登记卡片及其当前可用性；必需卡片允许移动但不能隐藏。
  const DashboardCardDefinition({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.required = false,
    this.available = true,
    this.fullWidth = false,
  });
  final String id;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
  final bool required;
  final bool available;
  final bool fullWidth;
}

/// 完整布局保留暂不可用以及新旧版本未知的编号。
class DashboardLayout {
  /// 创建不可变的顺序与隐藏集合快照。
  DashboardLayout({
    required Iterable<String> order,
    Iterable<String> hidden = const [],
  }) : order = List.unmodifiable(order),
       hidden = Set.unmodifiable(hidden);
  final List<String> order;
  final Set<String> hidden;

  /// 去除损坏和重复编号，追加新卡片并强制恢复必需项。
  DashboardLayout reconcile(List<DashboardCardDefinition> cards) {
    final ids = <String>{};
    final normalized = <String>[];
    for (final id in [...order, ...cards.map((card) => card.id)]) {
      if (id.trim().isNotEmpty && ids.add(id)) normalized.add(id);
    }
    final requiredIds = cards
        .where((card) => card.required)
        .map((card) => card.id)
        .toSet();
    return DashboardLayout(
      order: normalized,
      hidden: hidden.where(
        (id) => id.trim().isNotEmpty && !requiredIds.contains(id),
      ),
    );
  }

  /// 根据登记表筛出可见卡片，条件不满足时只跳过绘制。
  List<DashboardCardDefinition> visibleCards(
    List<DashboardCardDefinition> cards,
  ) {
    final byId = <String, DashboardCardDefinition>{};
    for (final card in cards) {
      if (card.id.trim().isNotEmpty) byId.putIfAbsent(card.id, () => card);
    }
    return [
      for (final id in order)
        if (byId[id] != null && byId[id]!.available && !hidden.contains(id))
          byId[id]!,
    ];
  }

  /// 设置可选卡片的隐藏状态，必需卡片始终保持显示。
  DashboardLayout setHidden(
    String id,
    bool value,
    List<DashboardCardDefinition> cards,
  ) {
    final next = {...hidden};
    if (value && !cards.any((card) => card.id == id && card.required)) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return DashboardLayout(order: order, hidden: next).reconcile(cards);
  }

  /// 重新添加卡片时移到完整顺序末尾，并保留其他卡片的隐藏状态。
  DashboardLayout addLast(String id, List<DashboardCardDefinition> cards) {
    final current = reconcile(cards);
    if (!cards.any((card) => card.id == id)) return current;
    return DashboardLayout(
      order: [...current.order.where((item) => item != id), id],
      hidden: current.hidden.where((item) => item != id),
    ).reconcile(cards);
  }

  /// 将一个编号移动到目标编号前后，保留其余未知及暂不可用项的位置。
  DashboardLayout move(String id, String target, {bool after = false}) {
    if (id == target || !order.contains(id) || !order.contains(target)) {
      return this;
    }
    final next = [...order]..remove(id);
    next.insert(next.indexOf(target) + (after ? 1 : 0), id);
    return DashboardLayout(order: next, hidden: hidden);
  }
}
