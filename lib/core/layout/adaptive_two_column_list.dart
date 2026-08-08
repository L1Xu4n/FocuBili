import 'package:flutter/material.dart';

///
/// 按当前可用宽度在单列和双列之间切换的通用滚动列表。
///
/// 组件只依赖窗口约束，不判断 Android、平板或 Windows，因此桌面端改变窗口大小时也能自然回流。
class AdaptiveTwoColumnList extends StatelessWidget {
  /// 创建保留普通 `ListView` 滚动能力的响应式列表，并允许分页尾部横跨整行。
  const AdaptiveTwoColumnList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.header,
    this.footer,
    this.breakpoint = 760,
    this.crossAxisSpacing = 12,
    this.mainAxisSpacing = 12,
    this.physics,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;
  final Widget? header;
  final Widget? footer;
  final double breakpoint;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final ScrollPhysics? physics;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// 构建当前条目，并给双列中较短的末行补空白而不是拉伸已有卡片。
  Widget _buildItem(BuildContext context, int index) {
    return itemBuilder(context, index);
  }

  /// 构建手机或窄窗口使用的普通单列，保持原页面的阅读顺序和滚动手感。
  Widget _buildSingleColumn(BuildContext context) {
    final int headerCount = header == null ? 0 : 1;
    final int totalCount = headerCount + itemCount + (footer == null ? 0 : 1);
    return ListView.builder(
      controller: controller,
      padding: padding,
      physics: physics,
      keyboardDismissBehavior: keyboardDismissBehavior,
      itemCount: totalCount,
      // 单列条目函数在数据项前后插入可选整行头部与分页尾部。
      itemBuilder: (BuildContext context, int index) {
        final bool isHeader = header != null && index == 0;
        final int dataIndex = index - headerCount;
        final bool isFooter = footer != null && dataIndex == itemCount;
        final Widget child = isHeader
            ? header!
            : isFooter
            ? footer!
            : _buildItem(context, dataIndex);
        final bool isLast = index == totalCount - 1;
        return Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : mainAxisSpacing),
          child: child,
        );
      },
    );
  }

  /// 构建宽窗口双列；同一行高度取两张卡片的较大值，分页尾部始终横跨整行。
  Widget _buildTwoColumns(BuildContext context) {
    final int headerRowCount = header == null ? 0 : 1;
    final int dataRowCount = (itemCount + 1) ~/ 2;
    final int totalRowCount =
        headerRowCount + dataRowCount + (footer == null ? 0 : 1);
    return ListView.builder(
      controller: controller,
      padding: padding,
      physics: physics,
      keyboardDismissBehavior: keyboardDismissBehavior,
      itemCount: totalRowCount,
      // 双列行函数让头尾横跨整行，并把相邻数据项放入中间的双列行。
      itemBuilder: (BuildContext context, int rowIndex) {
        final bool isHeader = header != null && rowIndex == 0;
        final int dataRowIndex = rowIndex - headerRowCount;
        final bool isFooter = footer != null && dataRowIndex == dataRowCount;
        final bool isLast = rowIndex == totalRowCount - 1;
        if (isHeader || isFooter) {
          return Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : mainAxisSpacing),
            child: isHeader ? header! : footer!,
          );
        }
        final int firstIndex = dataRowIndex * 2;
        final int secondIndex = firstIndex + 1;
        return Padding(
          key: Key('adaptive-list-row-$dataRowIndex'),
          padding: EdgeInsets.only(bottom: isLast ? 0 : mainAxisSpacing),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _buildItem(context, firstIndex)),
              SizedBox(width: crossAxisSpacing),
              Expanded(
                child: secondIndex < itemCount
                    ? _buildItem(context, secondIndex)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 根据父级实际分配宽度选择布局，使 Android 平板和未来 Windows 窗口共享同一断点。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return constraints.maxWidth >= breakpoint
            ? _buildTwoColumns(context)
            : _buildSingleColumn(context);
      },
    );
  }
}
