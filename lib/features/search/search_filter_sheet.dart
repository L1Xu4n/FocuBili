import 'package:flutter/material.dart';

/// 限制筛选面板高度，固定关闭入口和操作区，让较长的条件单独滚动。
class SearchFilterSheet extends StatelessWidget {
  /// 接收筛选内容、底部操作和关闭回调，草稿与保存逻辑由搜索页管理。
  const SearchFilterSheet({
    super.key,
    required this.content,
    required this.actions,
    required this.onClose,
  });

  final Widget content;
  final Widget actions;
  final VoidCallback onClose;

  /// 按键盘上方可用高度显示面板，保留外侧空隙与始终可见的关闭按钮。
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: LayoutBuilder(
          // 键盘占用高度已由外层扣除，剩余空间的 86% 用于筛选面板。
          builder: (BuildContext context, BoxConstraints constraints) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .86,
              ),
              child: Column(
                key: const Key('search-filter-sheet'),
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(left: 20, right: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '筛选',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          key: const Key('close-search-filter'),
                          tooltip: '关闭筛选',
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      key: const Key('search-filter-scroll'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: content,
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: actions,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
