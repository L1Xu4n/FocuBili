import 'dart:convert';
import 'dart:io';

/// 在本地或 CI 构建前生成真实 UTC 构建时间、源码提交和版本，不访问任何凭据。
Future<void> main() async {
  final version = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(await File('pubspec.yaml').readAsString())?.group(1);
  if (version == null) throw StateError('缺少构建版本');
  final commit = await Process.run('git', ['rev-parse', 'HEAD']);
  if (commit.exitCode != 0) throw StateError('无法读取源码提交');
  final revision = commit.stdout.toString().trim();
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) throw StateError('源码提交无效');
  await File('lib/core/build_metadata.g.dart').writeAsString(
    '// 构建时由 tool/write_build_metadata.dart 生成。\n'
    'const String appBuildTime = ${jsonEncode(DateTime.now().toUtc().toIso8601String())};\n'
    'const String appSourceRevision = ${jsonEncode(revision)};\n'
    'const String appFallbackVersion = ${jsonEncode(version)};\n',
  );
}
