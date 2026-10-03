// CI-only seed/verify app: two separately built versions share the production
// bundle ID. Tests container preservation, not cross-team signing migration.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment('UPGRADE_PHASE');
  final documents = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  await documents.create(recursive: true);
  await support.create(recursive: true);
  final report = File('${documents.path}/apple-upgrade-report.json');
  final note = File('${documents.path}/apple-upgrade-note.json');
  final offline = File('${support.path}/apple-upgrade-offline.bin');
  const token = 'focubili-upgrade-fixture-v1';
  final expectedNote = jsonEncode({'text': '升级保留：学习笔记', 'positionMs': 12000});
  final prefs = await SharedPreferences.getInstance();
  try {
    if (phase == 'seed') {
      await prefs.setString('apple_upgrade_token', token);
      await prefs.setDouble('apple_upgrade_rate', 1.5);
      await note.writeAsString(expectedNote, flush: true);
      await offline.writeAsBytes(List.generate(256, (i) => i), flush: true);
    } else if (phase == 'verify') {
      await prefs.reload();
      if (prefs.getString('apple_upgrade_token') != token ||
          prefs.getDouble('apple_upgrade_rate') != 1.5 ||
          !await note.exists() ||
          await note.readAsString() != expectedNote ||
          !await offline.exists() ||
          base64Encode(await offline.readAsBytes()) !=
              base64Encode(List.generate(256, (i) => i))) {
        throw StateError('Upgrade lost preferences, document or offline data');
      }
      await prefs.remove('apple_upgrade_token');
      await prefs.remove('apple_upgrade_rate');
      await note.delete();
      await offline.delete();
    } else {
      throw StateError('Unknown phase');
    }
    await report.writeAsString(
      jsonEncode({'phase': phase, 'success': true}),
      flush: true,
    );
    stdout.writeln('APPLE_UPGRADE_${phase.toUpperCase()}_PASSED');
    exit(0);
  } catch (error) {
    await report.writeAsString(
      jsonEncode({'phase': phase, 'success': false, 'error': '$error'}),
      flush: true,
    );
    stderr.writeln(error);
    exit(1);
  }
}
