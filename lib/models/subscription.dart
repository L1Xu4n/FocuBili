/// All subscription data is device-local and contains no credentials or play URLs.
enum SubscriptionKind { creator, collection }

class SubscriptionSource {
  const SubscriptionSource({
    required this.kind,
    required this.mid,
    this.seasonId,
    required this.name,
    required this.token,
    this.paused = false,
    this.imageUrl = '',
  });
  final SubscriptionKind kind;
  final int mid;
  final int? seasonId;
  final String name, token;
  final String imageUrl;
  final bool paused;
  String get key => kind == SubscriptionKind.creator
      ? 'creator:$mid'
      : 'collection:$mid:$seasonId';
  SubscriptionSource withPaused(bool value) => SubscriptionSource(
    kind: kind,
    mid: mid,
    seasonId: seasonId,
    name: name,
    token: token,
    paused: value,
    imageUrl: imageUrl,
  );
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'mid': mid,
    'seasonId': seasonId,
    'name': name,
    'token': token,
    'paused': paused,
    'imageUrl': imageUrl,
  };
  factory SubscriptionSource.fromJson(Map<String, dynamic> json) {
    final kind = SubscriptionKind.values.byName(json['kind'] as String);
    final mid = json['mid'] as int;
    final season = json['seasonId'] as int?;
    if (mid <= 0 ||
        (kind == SubscriptionKind.collection &&
            (season == null || season <= 0))) {
      throw const FormatException('Invalid source');
    }
    return SubscriptionSource(
      kind: kind,
      mid: mid,
      seasonId: season,
      name: json['name'] as String,
      token: json['token'] as String,
      paused: json['paused'] == true,
      imageUrl: json['imageUrl'] as String? ?? '',
    );
  }
}

class SubscriptionFeedItem {
  const SubscriptionFeedItem({
    required this.bvid,
    required this.title,
    required this.coverUrl,
    required this.sources,
    required this.discoveredAt,
    this.publishedAt,
    this.readAt,
    this.collectionAdded = false,
  });
  final String bvid, title, coverUrl;
  final Map<String, String> sources;
  final DateTime discoveredAt;
  final DateTime? publishedAt, readAt;
  final bool collectionAdded;
  SubscriptionFeedItem copyWith({
    Map<String, String>? sources,
    DateTime? readAt,
    bool? collectionAdded,
  }) => SubscriptionFeedItem(
    bvid: bvid,
    title: title,
    coverUrl: coverUrl,
    sources: Map.unmodifiable(sources ?? this.sources),
    discoveredAt: discoveredAt,
    publishedAt: publishedAt,
    readAt: readAt ?? this.readAt,
    collectionAdded: collectionAdded ?? this.collectionAdded,
  );
  Map<String, Object?> toJson() => {
    'bvid': bvid,
    'title': title,
    'coverUrl': coverUrl,
    'sources': sources,
    'discoveredAt': discoveredAt.toIso8601String(),
    'publishedAt': publishedAt?.toIso8601String(),
    'readAt': readAt?.toIso8601String(),
    'collectionAdded': collectionAdded,
  };
  factory SubscriptionFeedItem.fromJson(Map<String, dynamic> j) =>
      SubscriptionFeedItem(
        bvid: j['bvid'] as String,
        title: j['title'] as String,
        coverUrl: j['coverUrl'] as String,
        sources: Map<String, String>.unmodifiable(j['sources'] as Map),
        discoveredAt: DateTime.parse(j['discoveredAt'] as String),
        publishedAt: j['publishedAt'] == null
            ? null
            : DateTime.parse(j['publishedAt'] as String),
        readAt: j['readAt'] == null
            ? null
            : DateTime.parse(j['readAt'] as String),
        collectionAdded: j['collectionAdded'] == true,
      );
}

/// Persistent dedupe index is independent from the 500-item display cache.
class SourceCheckpoint {
  SourceCheckpoint({
    Set<String>? seen,
    this.initialized = false,
    this.nextPage = 1,
    Map<String, SubscriptionFeedItem>? pending,
    this.firstPage = const [],
    this.total,
    this.lastSuccess,
    this.failures = 0,
    this.retryAt,
    this.error,
    this.algorithm = 2,
    this.baselineAt,
    this.fullBaseline = false,
    this.watermark,
    this.scanNewest,
    this.knownPages = 0,
    this.blocked = false,
    this.needsHeadRecheck = false,
    this.catchingUp = false,
    Set<String>? anchors,
    Map<String, int>? signatures,
    this.secondPage = const [],
  }) : anchors = anchors ?? {},
       signatures = signatures ?? {},
       seen = seen ?? {},
       pending = pending ?? {};
  Set<String> seen;
  bool initialized;
  int nextPage, failures;
  Map<String, SubscriptionFeedItem> pending;
  List<String> firstPage;
  int? total;
  DateTime? lastSuccess, retryAt;
  String? error;
  int algorithm, knownPages;
  bool fullBaseline, blocked, needsHeadRecheck, catchingUp;
  DateTime? baselineAt, watermark, scanNewest;
  Set<String> anchors;
  Map<String, int> signatures;
  List<String> secondPage;
  bool get partial =>
      catchingUp || nextPage > 1 || (algorithm == 1 && pending.isNotEmpty);
  Map<String, Object?> toJson() => {
    'algorithm': algorithm,
    'baselineAt': baselineAt?.toIso8601String(),
    'fullBaseline': fullBaseline,
    'watermark': watermark?.toIso8601String(),
    'scanNewest': scanNewest?.toIso8601String(),
    'knownPages': knownPages,
    'blocked': blocked,
    'needsHeadRecheck': needsHeadRecheck,
    'catchingUp': catchingUp,
    'anchors': anchors.toList(),
    'signatures': signatures,
    'secondPage': secondPage,
    'seen': seen.toList(),
    'initialized': initialized,
    'nextPage': nextPage,
    'pending': pending.values.map((e) => e.toJson()).toList(),
    'firstPage': firstPage,
    'total': total,
    'lastSuccess': lastSuccess?.toIso8601String(),
    'failures': failures,
    'retryAt': retryAt?.toIso8601String(),
    'error': error,
  };
  factory SourceCheckpoint.fromJson(Map<String, dynamic> j) => SourceCheckpoint(
    algorithm: j['algorithm'] as int? ?? 1,
    baselineAt: DateTime.tryParse(j['baselineAt'] as String? ?? ''),
    fullBaseline: j['fullBaseline'] == true,
    watermark: DateTime.tryParse(j['watermark'] as String? ?? ''),
    scanNewest: DateTime.tryParse(j['scanNewest'] as String? ?? ''),
    knownPages: j['knownPages'] as int? ?? 0,
    blocked: j['blocked'] == true,
    needsHeadRecheck: j['needsHeadRecheck'] == true,
    catchingUp: j['catchingUp'] == true,
    anchors: Set<String>.from(j['anchors'] as List? ?? []),
    signatures: Map<String, int>.from(j['signatures'] as Map? ?? {}),
    secondPage: List<String>.from(j['secondPage'] as List? ?? []),
    seen: Set<String>.from(j['seen'] as List),
    initialized: j['initialized'] == true,
    nextPage: j['nextPage'] as int,
    pending: {
      for (final x in j['pending'] as List)
        (x as Map)['bvid'] as String: SubscriptionFeedItem.fromJson(
          Map<String, dynamic>.from(x),
        ),
    },
    firstPage: List<String>.from(j['firstPage'] as List),
    total: j['total'] as int?,
    lastSuccess: j['lastSuccess'] == null
        ? null
        : DateTime.parse(j['lastSuccess'] as String),
    failures: j['failures'] as int,
    retryAt: j['retryAt'] == null
        ? null
        : DateTime.parse(j['retryAt'] as String),
    error: j['error'] as String?,
  );
}
