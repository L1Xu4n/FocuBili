// CI-only entry point: synthetic generations, no subscription store, account,
// HTTP request or notification. Normal distribution packages are built first.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_subscription_scheduler.dart';

class RecordingSchedulerChannel extends MethodChannel {
  RecordingSchedulerChannel()
    : super('com.focubili.app/subscription_scheduler');
  int rawTicks = 0;
  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? handler) {
    super.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method == 'check') rawTicks++;
              return handler(call);
            },
    );
  }
}

@pragma('vm:entry-point')
Future<void> nativeSubscriptionHeadlessProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/subscription_worker');
  final request = await channel.invokeMapMethod<Object?, Object?>('ready');
  await channel.invokeMethod<bool>('complete', {
    'runId': request?['runId'],
    'success': request?['probe'] == true,
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('NATIVE_SUBSCRIPTION_PROBE')) {
    throw StateError('Explicit isolated CI probe opt-in required');
  }
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Native subscription CI probe'))),
    ),
  );
  final channel = RecordingSchedulerChannel();
  final platform = AppPlatformDetector.current;
  final native = NativeSubscriptionScheduler(
    platform: platform,
    channel: channel,
    interval: const Duration(seconds: 1),
  );
  final report = <String, Object?>{
    'success': false,
    'platform': platform.name,
    'runId': const String.fromEnvironment('NATIVE_SUBSCRIPTION_PROBE_RUN_ID'),
    if (platform.isDesktop)
      'requestId':
          Platform.environment['FOCUBILI_NATIVE_SUBSCRIPTION_REQUEST_ID'],
    'checks': <String>[],
  };
  final checks = report['checks']! as List<String>;
  final ticks = <int>[];
  Future<void> waitFor(int generation) async {
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (!ticks.contains(generation) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!ticks.contains(generation)) {
      throw StateError('Native timer did not tick');
    }
  }

  try {
    await native.initialize((generation) async {
      ticks.add(generation);
    });
    if (platform == AppPlatform.ios) {
      final status = await channel.invokeMapMethod<Object?, Object?>(
        'getStatus',
      );
      if (status?['registered'] != true || native.mode != 'opportunistic') {
        throw StateError('BGAppRefresh launch registration missing');
      }
      checks.add('ios_launch_registration');
      // Simulator does not promise BGAppRefresh launches. Never equate this
      // registration/bridge smoke test with real opportunistic delivery.
      // No request was submitted here, so a successful cancel reply does not
      // verify that an existing OS pending request was actually removed.
      await native.configure(false, 101);
      checks.add('ios_cancel_method_completed');
      if (await channel.invokeMethod<bool>('probeHeadlessEngine') != true) {
        throw StateError('Headless engine bootstrap did not complete');
      }
      checks.add('ios_headless_engine_handshake');
    } else {
      if (!native.available || native.mode != 'process') {
        throw StateError('Process-owned native scheduler unavailable');
      }
      await native.configure(true, 101);
      await waitFor(101);
      checks.add('native_timer_callback');
      await native.configure(true, 102);
      await waitFor(102);
      checks.add('native_generation_replacement');
      await native.configure(false, 103);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final stopped = channel.rawTicks;
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      if (channel.rawTicks != stopped) {
        throw StateError('Cancelled timer kept ticking');
      }
      checks.add('native_timer_cancel');
    }
    report['success'] = true;
  } catch (error) {
    report['errorType'] = error.runtimeType.toString();
    report['error'] = error is StateError
        ? error.message
        : 'Native bridge failed';
  } finally {
    await native.dispose();
    if (platform == AppPlatform.ios) {
      final folder = await getApplicationDocumentsDirectory();
      final destination = File(
        '${folder.path}/native-subscription-result.json',
      );
      final temporary = File('${destination.path}.tmp');
      await temporary.writeAsString(jsonEncode(report), flush: true);
      await temporary.rename(destination.path);
    } else {
      // The macOS app keeps its production sandbox. Only the host runner may
      // write a report into the CI workspace; return this run's result on stdout.
      if (platform != AppPlatform.macos) {
        final reportPath =
            Platform.environment['FOCUBILI_NATIVE_SUBSCRIPTION_REPORT'];
        if (reportPath != null && reportPath.isNotEmpty) {
          await File(reportPath).writeAsString(jsonEncode(report), flush: true);
        }
      }
      stdout.writeln('NATIVE_SUBSCRIPTION_RESULT ${jsonEncode(report)}');
      await stdout.flush();
      exit(report['success'] == true ? 0 : 1);
    }
  }
}
