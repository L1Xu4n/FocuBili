import 'subscription.dart';

enum HistoryImportStatus { paused, running, complete, limited, blocked, failed }

/// Independent from live dedupe/notification state. Large metadata lives in
/// immutable page files; only task progress and exact IDs enter the snapshot.
class SubscriptionHistoryJob {
  SubscriptionHistoryJob({
    required this.id,
    required this.sourceKey,
    required this.sourceToken,
    this.limit = 100,
    this.nextPage = 1,
    this.batches = 0,
    this.status = HistoryImportStatus.paused,
    Set<String>? ids,
    Map<String, int>? signatures,
    this.total,
    this.error,
    this.retryAt,
    this.failures = 0,
    this.runOwner,
    this.runUntil,
    this.revisit = false,
    this.listChanged = false,
  }) : ids = ids ?? {},
       signatures = signatures ?? {};
  final String id, sourceKey;
  String sourceToken;
  int? limit;
  int nextPage, batches, failures;
  int? total;
  HistoryImportStatus status;
  Set<String> ids;
  Map<String, int> signatures;
  String? error, runOwner;
  DateTime? runUntil;
  bool revisit, listChanged;
  DateTime? retryAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'sourceKey': sourceKey,
    'sourceToken': sourceToken,
    'limit': limit,
    'nextPage': nextPage,
    'batches': batches,
    'status': status.name,
    'ids': ids.toList(),
    'signatures': signatures,
    'total': total,
    'error': error,
    'retryAt': retryAt?.toIso8601String(),
    'failures': failures,
    'runOwner': runOwner,
    'runUntil': runUntil?.toIso8601String(),
    'revisit': revisit,
    'listChanged': listChanged,
  };
  factory SubscriptionHistoryJob.fromJson(Map<String, dynamic> j) =>
      SubscriptionHistoryJob(
        id: j['id'] as String,
        sourceKey: j['sourceKey'] as String,
        sourceToken: j['sourceToken'] as String,
        limit: j['limit'] as int?,
        nextPage: j['nextPage'] as int,
        batches: j['batches'] as int,
        status: HistoryImportStatus.values.byName(j['status'] as String),
        ids: Set<String>.from(j['ids'] as List),
        signatures: Map<String, int>.from(j['signatures'] as Map),
        total: j['total'] as int?,
        error: j['error'] as String?,
        retryAt: DateTime.tryParse(j['retryAt'] as String? ?? ''),
        failures: j['failures'] as int? ?? 0,
        runOwner: j['runOwner'] as String?,
        runUntil: DateTime.tryParse(j['runUntil'] as String? ?? ''),
        revisit: j['revisit'] == true,
        listChanged: j['listChanged'] == true,
      );
}

class SubscriptionHistoryBatch {
  const SubscriptionHistoryBatch({
    required this.page,
    required this.items,
    required this.hasMore,
    required this.signature,
    this.total,
  });
  final int page;
  final List<SubscriptionFeedItem> items;
  final bool hasMore;
  final String signature;
  final int? total;
  Map<String, Object?> toJson() => {
    'page': page,
    'items': items.map((e) => e.toJson()).toList(),
    'hasMore': hasMore,
    'signature': signature,
    'total': total,
  };
  factory SubscriptionHistoryBatch.fromJson(Map<String, dynamic> j) =>
      SubscriptionHistoryBatch(
        page: j['page'] as int,
        items: [
          for (final x in j['items'] as List)
            SubscriptionFeedItem.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
        hasMore: j['hasMore'] as bool,
        signature: j['signature'] as String,
        total: j['total'] as int?,
      );
}
