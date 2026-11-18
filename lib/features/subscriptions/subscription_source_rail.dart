import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/subscription.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/subscription_source_visits.dart';
import '../common/app_network_image.dart';

class SubscriptionSourceRail extends StatefulWidget {
  const SubscriptionSourceRail({
    super.key,
    required this.sources,
    required this.visibleFeed,
    required this.retainedFeed,
    required this.selected,
    required this.onSelect,
    required this.actionsReady,
  });
  final List<SubscriptionSource> sources;
  final List<SubscriptionFeedItem> visibleFeed, retainedFeed;
  final String? selected;
  final bool actionsReady;
  final ValueChanged<String?> onSelect;
  @override
  State<SubscriptionSourceRail> createState() => _SubscriptionSourceRailState();
}

class _SubscriptionSourceRailState extends State<SubscriptionSourceRail> {
  Map<String, Set<String>>? _visits;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    CacheLifecycle.account.addListener(_scopeChanged);
    unawaited(_load());
  }

  void _scopeChanged() {
    setState(() => _visits = null);
    widget.onSelect(null);
    unawaited(_load());
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final scope = CacheLifecycle.accountScope;
    try {
      final visits = await SubscriptionSourceVisits.load(scope);
      if (mounted &&
          token == _loadToken &&
          scope == CacheLifecycle.accountScope) {
        setState(() => _visits = visits);
      }
    } catch (_) {
      // Filtering remains usable; never guess whether a source is new.
    }
  }

  @override
  void dispose() {
    CacheLifecycle.account.removeListener(_scopeChanged);
    super.dispose();
  }

  Future<void> _choose(SubscriptionSource source, Set<String> events) async {
    final identity = SubscriptionSourceVisits.identity(source);
    final scope = CacheLifecycle.accountScope;
    final revision = CacheLifecycle.account.value;
    widget.onSelect(source.key);
    if (!widget.actionsReady || events.isEmpty) return;
    final retain = widget.retainedFeed
        .map(SubscriptionSourceVisits.event)
        .toSet();
    final live = widget.sources.map(SubscriptionSourceVisits.identity).toSet();
    try {
      await SubscriptionSourceVisits.acknowledge(
        scope: scope,
        revision: revision,
        source: identity,
        presented: events,
        retainedEvents: retain,
        liveSources: live,
        stillVisible: () =>
            mounted &&
            widget.actionsReady &&
            widget.sources.any(
              (s) => SubscriptionSourceVisits.identity(s) == identity,
            ) &&
            widget.visibleFeed
                .where((e) => e.sources.containsKey(source.key))
                .map(SubscriptionSourceVisits.event)
                .toSet()
                .containsAll(events),
      );
      if (mounted &&
          scope == CacheLifecycle.accountScope &&
          revision == CacheLifecycle.account.value) {
        await _load();
      }
    } catch (_) {
      if (mounted &&
          scope == CacheLifecycle.accountScope &&
          revision == CacheLifecycle.account.value) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('来源提示未保存，可点按来源重试。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = <String, Set<String>>{};
    final latest = <String, DateTime>{};
    for (final item in widget.visibleFeed) {
      for (final key in item.sources.keys) {
        (events[key] ??= {}).add(SubscriptionSourceVisits.event(item));
        if (latest[key] == null || latest[key]!.isBefore(item.discoveredAt)) {
          latest[key] = item.discoveredAt;
        }
      }
    }
    final sources = widget.sources;
    bool fresh(SubscriptionSource source) {
      if (_visits == null || !widget.actionsReady) return false;
      final seen = _visits![SubscriptionSourceVisits.identity(source)];
      return events[source.key]?.any((id) => seen?.contains(id) != true) ??
          false;
    }

    // Unopened updates first; preserve the selected source's place while its
    // filter is active. Tied timestamps keep the original subscription order.
    final priority = {
      for (final s in sources)
        s.key:
            fresh(s) || (widget.selected == s.key && latest.containsKey(s.key)),
    };
    final rank = {for (final (i, s) in sources.indexed) s.key: i};
    final sorted = sources.toList()
      ..sort((a, b) {
        if (priority[a.key] != priority[b.key]) {
          return priority[a.key]! ? -1 : 1;
        }
        final at = latest[a.key], bt = latest[b.key];
        final order = at == null
            ? (bt == null ? 0 : 1)
            : bt == null
            ? -1
            : bt.compareTo(at);
        return order != 0 ? order : rank[a.key]!.compareTo(rank[b.key]!);
      });
    final scroll = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: scroll.copyWith(
        dragDevices: {...scroll.dragDevices, PointerDeviceKind.mouse},
      ),
      child: ListView(
        key: const Key('subscription-source-filters'),
        scrollDirection: Axis.horizontal,
        children: [
          _SourceChip(
            label: '全部来源',
            selected: widget.selected == null,
            fresh: false,
            icon: const Icon(Icons.layers_outlined, size: 19),
            onTap: () => widget.onSelect(null),
          ),
          for (final source in sorted)
            _SourceChip(
              key: ValueKey('source-filter-${source.key}'),
              label: source.name,
              selected: source.key == widget.selected,
              fresh: fresh(source),
              icon: _Avatar(source: source),
              onTap: () => unawaited(_choose(source, events[source.key] ?? {})),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.source});
  final SubscriptionSource source;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: color.secondaryContainer,
      child: Icon(
        source.kind == SubscriptionKind.creator
            ? Icons.person_outline
            : Icons.video_library_outlined,
        size: 16,
        color: color.onSecondaryContainer,
      ),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox.square(
          dimension: 20,
          child: source.imageUrl.isEmpty
              ? fallback
              : AppNetworkImage(
                  imageUrl: source.imageUrl,
                  httpHeaders: const {'Referer': 'https://www.bilibili.com/'},
                  memCacheWidth: 60,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}

class _SourceChip extends StatefulWidget {
  const _SourceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.fresh,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final bool selected, fresh;
  final Widget icon;
  final VoidCallback onTap;
  @override
  State<_SourceChip> createState() => _SourceChipState();
}

class _SourceChipState extends State<_SourceChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  Timer? _pause;
  bool _running = false;
  @override
  void initState() {
    super.initState();
    _glow.addStatusListener(_status);
  }

  void _status(AnimationStatus status) {
    if (status == AnimationStatus.completed && _running) {
      _pause = Timer(const Duration(milliseconds: 850), () {
        if (_running) _glow.forward(from: 0);
      });
    }
  }

  void _sync() {
    final should =
        widget.fresh &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_running == should) return;
    _running = should;
    _pause?.cancel();
    if (should) {
      _glow.forward(from: 0);
    } else {
      _glow.stop();
      _glow.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _SourceChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pause?.cancel();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(11);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.icon,
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            widget.label,
            style: Theme.of(context).textTheme.labelLarge,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        if (widget.fresh) ...[
          const SizedBox(width: 6),
          Icon(
            Icons.circle,
            size: 7,
            color: colors.primary,
            key: const Key('source-new-dot'),
          ),
        ],
      ],
    );
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      onTap: widget.onTap,
      label: '${widget.label}${widget.fresh ? '，有新更新' : ''}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: radius,
            child: Center(
              child: AnimatedBuilder(
                animation: _glow,
                child: content,
                builder: (context, child) {
                  final k = math
                      .pow(math.sin(math.pi * _glow.value), 2)
                      .toDouble();
                  return Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * .72,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      color: widget.selected
                          ? colors.secondaryContainer
                          : colors.surface,
                      border: Border.all(
                        color: widget.fresh
                            ? colors.primary.withValues(alpha: .55 + k * .4)
                            : widget.selected
                            ? colors.secondaryContainer
                            : colors.outlineVariant,
                      ),
                      boxShadow: widget.fresh && _running
                          ? [
                              BoxShadow(
                                color: colors.primary.withValues(
                                  alpha: .08 + k * .17,
                                ),
                                blurRadius: 2 + 4 * k,
                              ),
                            ]
                          : null,
                    ),
                    child: child,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
