import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/subscription_request_scope.dart';

class HeldClient implements HttpClient {
  final entered = Completer<void>();
  final response = Completer<HttpClientRequest>();
  int forceCloses = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    entered.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) {
    if (force) forceCloses++;
    if (!response.isCompleted) {
      response.completeError(const SocketException('cancelled'));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'scoped cancellation closes the actual public HTTP client before a late response',
    () async {
      final client = HeldClient();
      final scope = SubscriptionRequestScope();
      await HttpOverrides.runZoned(() async {
        final request = scope.run(
          () => BilibiliHttpPublicContentService().loadCollectionVideos(1, 2),
        );
        final failed = expectLater(request, throwsA(isA<Exception>()));
        await client.entered.future;
        scope.cancel();
        await failed;
        expect(client.forceCloses, greaterThanOrEqualTo(1));
      }, createHttpClient: (_) => client);
    },
  );
  test(
    'real request starts are spaced and cancellation drains a queued request',
    () async {
      final first = SubscriptionRequestScope();
      final second = SubscriptionRequestScope();
      await first.beforeRequest();
      final watch = Stopwatch()..start();
      await second.beforeRequest();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(850));
      final cancelled = SubscriptionRequestScope();
      final queued = cancelled.beforeRequest();
      final failed = expectLater(queued, throwsStateError);
      cancelled.cancel();
      await failed;
    },
  );
}
