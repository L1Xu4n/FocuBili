import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/playback_queue.dart';

/// 覆盖分页并发、失败重试、末项和无进展保护，不引入媒体后端替身。
void main() {
  const first = PlaybackQueueItem(bvid: 'one', title: '第一项');
  const second = PlaybackQueueItem(bvid: 'two', title: '第二项');
  test(
    'pagination deduplicates, coalesces and retains the failed page',
    () async {
      final gate = Completer<PlaybackQueuePage>();
      final requested = <int>[];
      var fail = true;
      final queue = PlaybackQueue(
        title: '收藏',
        items: [first],
        hasMore: true,
        nextPage: 2,
        loadPage: (page) async {
          requested.add(page);
          if (fail) throw StateError('offline');
          return gate.future;
        },
      );
      expect(await queue.nextAfter('one', 1), isNull);
      expect(queue.error, isNotNull);
      expect(queue.items, [first]);
      fail = false;
      final loading = queue.loadMore();
      final same = queue.loadMore();
      gate.complete(const PlaybackQueuePage([first, second], hasMore: false));
      await Future.wait([loading, same]);
      expect(requested, [2, 2]);
      expect(queue.items, [first, second]);
      expect(await queue.nextAfter('one', 1), second);
      expect(await queue.nextAfter('two', 1), isNull);
      expect(queue.error, isNull);
      queue.dispose();
    },
  );
  test('repeated pages cannot spin forever or masquerade as the end', () async {
    final queue = PlaybackQueue(
      title: '合集',
      items: [first],
      hasMore: true,
      loadPage: (_) async => const PlaybackQueuePage([first], hasMore: true),
    );
    expect(await queue.nextAfter('one', 1), isNull);
    expect(queue.hasMore, isTrue);
    expect(queue.error, isNotNull);
    queue.dispose();
  });
}
