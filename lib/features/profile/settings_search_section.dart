import 'package:flutter/material.dart';

/// 设置的补充别名；页面标题和说明由组件自动读取，不依赖这张表登记。
final _settingsAliases = <Key, String>{
  Key('enable-account-read-only'): '账号只读 点赞 投币 收藏 隐私',
  Key('enable-search-history'): '启用搜索记录 隐私',
  Key('enable-watch-history'): '启用观看记录 观看进度 隐私',
  Key('enable-windows-clipboard-link-detection'): '检测剪贴板中的 B站链接 粘贴',
  Key('wifi-default-quality-tile'): 'Wi-Fi 有线 默认清晰度 画质',
  Key('mobile-default-quality-tile'): '移动网络 默认清晰度 画质 流量',
  Key('playback-speeds-preference'): '自定义播放倍速 快进速度 5x',
  Key('player-control-size-preference'):
      '播放栏 控制栏 大小 播放器 按钮 图标 文字 字号 缩放 点击 预览 size playback bar',
  Key('enable-double-tap-seek'): '启用双击快进快退 播放器手势',
  Key('double-tap-regions-preference'):
      '自定义 双击 触发区 区域 分区 范围 分割线 边界 宽度 高度 全屏 预览 手势 double tap region',
  Key('show-playback-action-animation'):
      '播放暂停动画 开始播放 暂停 标志 图标 缩小 淡出 反馈 animation',
  Key('show-note-time-markers'): '显示笔记时间标记 笔记旗标 时间点 播放器',
  Key('enable-two-finger-video-transform'): '启用双指缩放画面 全屏 拖动 双指双击恢复画面 播放器手势',
  Key('enable-focus-do-not-disturb'): '专注 勿扰 通知 Windows 系统专注',
  Key('theme-mode-setting'): '主题模式 浅色 深色 跟随系统 外观',
  Key('theme-color-setting'): '主题强调色 蓝色 B站粉 玫红 珊瑚橙 翠绿 湖蓝 薰衣草紫 外观',
  Key('open-android-permissions'): '权限管理 系统能力 通知 后台运行',
  Key('enable-startup-update-check'): '启动时检查更新 GitHub Release',
  Key('open-cache-management'): '视频缓存管理 存储 空间 清理',
  Key('open-about-page'): '关于 项目地址 负责人 版本 更新',
};

/// 对实际存在的设置项做文本搜索，并渲染同一套可操作的分类内容。
class SettingsSearchSection extends StatelessWidget {
  /// 自动匹配标题/说明及补充别名，保留原设置控件和点击回调。
  SettingsSearchSection({
    super.key,
    required this.icon,
    required this.title,
    required List<Widget> children,
    String query = '',
  }) : items = children.where((item) => _matches(item, query)).toList();

  final IconData icon;
  final String title;
  final List<Widget> items;

  /// 让首页根据当前平台真正可见的结果决定是否显示无匹配提示。
  bool get isEmpty => items.isEmpty;

  /// 忽略大小写、空白和常见分隔符，让“播放暂停”匹配“播放 / 暂停”。
  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s/／·、，,。:：_\-]+'), '');

  /// 从标准设置控件及布局容器读取实际展示的标题和说明。
  static String _visibleText(Widget? widget) {
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText() ?? '';
    }
    if (widget is ListTile) {
      return '${_visibleText(widget.title)} ${_visibleText(widget.subtitle)}';
    }
    if (widget is SwitchListTile) {
      return '${_visibleText(widget.title)} ${_visibleText(widget.subtitle)}';
    }
    if (widget is SingleChildRenderObjectWidget) {
      return _visibleText(widget.child);
    }
    if (widget is ProxyWidget) return _visibleText(widget.child);
    if (widget is MultiChildRenderObjectWidget) {
      return widget.children.map(_visibleText).join(' ');
    }
    return '';
  }

  /// 每个搜索词都必须命中标题、说明或别名，空查询保留全部当前平台项目。
  static bool _matches(Widget item, String query) {
    final terms = query
        .trim()
        .split(RegExp(r'\s+'))
        .map(_normalize)
        .where((term) => term.isNotEmpty);
    final text = _normalize(
      '${_visibleText(item)} ${_settingsAliases[item.key] ?? ''}',
    );
    return terms.every(text.contains);
  }

  /// 无结果不占空间；有结果保留分类标题、分隔线和实际可操作设置。
  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const Divider(height: 1),
        for (var index = 0; index < items.length; index++) ...[
          items[index],
          if (index < items.length - 1) const Divider(height: 1),
        ],
      ],
    );
  }
}
