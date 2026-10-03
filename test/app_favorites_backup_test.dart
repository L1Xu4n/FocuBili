import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/app_favorites_backup.dart';
import 'package:focubili/services/app_favorites_file_service.dart';
import 'package:focubili/services/app_favorites_service.dart';

final collectedAt = DateTime.utc(2026, 9, 1, 12, 30);

/// 构造固定时间的目录，便于检测导入是否意外重置元数据。
AppFavoriteFolder folder(String id, String name) => AppFavoriteFolder(
  id: id,
  name: name,
  createdAt: collectedAt,
  updatedAt: collectedAt,
);

/// 构造包含所有可迁移字段的收藏项。
AppFavoriteItem item(
  String folderId,
  String bvid, {
  String title = '学习 🎉 中文',
}) => AppFavoriteItem(
  folderId: folderId,
  bvid: bvid,
  title: title,
  coverUrl: 'https://example.com/cover.jpg',
  ownerName: '老师',
  durationText: '12:30',
  addedAt: collectedAt,
  partCount: 3,
);

/// 构造包含多目录、空目录和跨目录重复视频的真实备份。
AppFavoritesBackup sample() => AppFavoritesBackup(
  folders: [
    folder('study', '学习'),
    folder('empty', '空收藏夹'),
    folder('music', '音乐'),
  ],
  items: {
    'study': [item('study', 'BV1GJ411x7h7'), item('study', 'BV1xx411c7mD')],
    'music': [item('music', 'BV1GJ411x7h7')],
  },
  exportedAt: DateTime.utc(2026, 10, 3),
);

/// 写入到内存后模拟磁盘拒绝或异常，覆盖偏好缓存也已变化的失败场景。
class FailingPreferences implements SharedPreferences {
  FailingPreferences(
    this.delegate, {
    required this.failOnWrite,
    this.throws = false,
  });
  final SharedPreferences delegate;
  final int failOnWrite;
  final bool throws;
  int writes = 0;

  @override
  String? getString(String key) => delegate.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    final saved = await delegate.setString(key, value);
    if (++writes == failOnWrite) {
      if (throws) throw const FileSystemException('disk full');
      return false;
    }
    return saved;
  }

  @override
  Future<bool> remove(String key) => delegate.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 模拟系统另存为并真正写文件，确保调用者交给插件的是完整字节。
class RecordingFilePicker extends FilePickerPlatform {
  String? destination;
  Uint8List? savedBytes;
  String? proposedName;
  bool locked = false;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    savedBytes = bytes;
    proposedName = fileName;
    locked = lockParentWindow;
    if (destination == null) return null;
    await File(destination!).writeAsBytes(bytes!, flush: true);
    return destination;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('UTF-8 备份完整往返，保留空目录、顺序、时间、多 P 和跨目录收藏', () async {
    final original = sample();
    final decoded = AppFavoritesBackup.fromBytes(original.toBytes());
    final service = AppFavoritesService();
    final result = await service.importBackup(decoded);
    expect(result.createdFolders, 3);
    expect(result.importedItems, 3);
    final restored = await service.exportBackup();
    expect(
      restored.folders.map((e) => e.toJson()),
      original.folders.map((e) => e.toJson()),
    );
    for (final entry in original.items.entries) {
      expect(
        restored.items[entry.key]!.map((e) => e.toJson()),
        entry.value.map((e) => e.toJson()),
      );
    }
    expect((await service.exportBackup(folderId: 'study')).itemCount, 2);
    expect(
      (await service.exportBackup(folderId: 'empty')).folders.single.name,
      '空收藏夹',
    );
    await expectLater(
      service.exportBackup(folderId: 'missing'),
      throwsStateError,
    );
  });

  test('同名目录合并并重映射目录引用，重复视频保留本机信息，反复导入不新增', () async {
    final service = AppFavoritesService();
    final local = (await service.createFolder('学习'))!;
    await service.addItem(item(local.id, 'BV1GJ411x7h7', title: '本机已改名'));
    final result = await service.importBackup(sample());
    expect(result.createdFolders, 2);
    expect(result.importedItems, 2);
    expect(result.duplicates, 1);
    final entries = await service.loadItems(local.id);
    expect(entries.map((e) => e.folderId).toSet(), {local.id});
    expect(entries.firstWhere((e) => e.bvid == 'BV1GJ411x7h7').title, '本机已改名');
    final repeated = await service.importBackup(sample());
    expect(repeated.createdFolders, 0);
    expect(repeated.importedItems, 0);
    expect(repeated.duplicates, 3);
    expect(await service.loadFolders(), hasLength(3));
  });

  test('同标识目录优先，恢复旧备份不会撤销本机重命名', () async {
    final service = AppFavoritesService();
    await service.importBackup(sample());
    await service.renameFolder('study', '已改名');
    final named = (await service.createFolder('学习'))!;
    await service.importBackup(sample());
    expect((await service.loadFolders()).first.name, '已改名');
    expect(await service.loadItems(named.id), isEmpty);
    expect(await service.loadItems('study'), hasLength(2));
  });

  test('备份内独立同名目录保持独立，相同标识的目录不会被名称匹配提前占用', () async {
    final service = AppFavoritesService();
    final backup = AppFavoritesBackup(
      folders: [folder('first', '同名'), folder('second', '同名')],
      items: {
        'first': [item('first', 'BV1GJ411x7h7')],
        'second': [item('second', 'BV1xx411c7mD')],
      },
      exportedAt: collectedAt,
    );
    await service.importBackup(backup);
    expect(await service.loadFolders(), hasLength(2));
    expect((await service.loadItems('first')).single.bvid, 'BV1GJ411x7h7');
    expect((await service.loadItems('second')).single.bvid, 'BV1xx411c7mD');
    expect((await service.importBackup(backup)).importedItems, 0);

    await service.deleteFolder('first');
    final result = await service.importBackup(backup);
    expect(result.createdFolders, 1);
    expect((await service.loadItems('first')).single.bvid, 'BV1GJ411x7h7');
    expect((await service.loadItems('second')).single.bvid, 'BV1xx411c7mD');
  });

  test('文件内重复 BV 去重，不合并不同目录内的同一视频', () async {
    final root = jsonDecode(utf8.decode(sample().toBytes())) as Map;
    final entries = root['folders'][0]['items'] as List;
    entries.add(Map.from(entries.first));
    final result = await AppFavoritesService().importBackup(
      AppFavoritesBackup.fromBytes(utf8.encode(jsonEncode(root))),
    );
    expect(result.importedItems, 3);
    expect(result.duplicates, 1);
  });

  test('拒绝损坏字段、未知版本和错误目录引用，支持 UTF-8 BOM', () {
    expect(
      AppFavoritesBackup.fromBytes([
        0xef,
        0xbb,
        0xbf,
        ...sample().toBytes(),
      ]).itemCount,
      3,
    );
    final invalid = <void Function(Map)>[
      (root) => root['format'] = 'other',
      (root) => root['version'] = 99,
      (root) => root['folders'][0]['name'] = 42,
      (root) => root['folders'][0]['createdAt'] = 'broken',
      (root) => root['folders'][0]['items'][0]['folderId'] = 'other',
      (root) => root['folders'][0]['items'][0]['bvid'] = 'https://example.com',
      (root) => root['folders'][0]['items'][0]['partCount'] = 2.5,
      (root) => root['folders'][0]['items'][0]['ownerName'] = {},
      (root) => root['folders'][1]['id'] = 'study',
    ];
    for (final damage in invalid) {
      final root = jsonDecode(utf8.decode(sample().toBytes())) as Map;
      damage(root);
      expect(
        () => AppFavoritesBackup.fromBytes(utf8.encode(jsonEncode(root))),
        throwsFormatException,
      );
    }
    expect(() => AppFavoritesBackup.fromBytes([0xff]), throwsFormatException);
  });

  test('预检本机损坏目录时整个导入不写入，公开模型也不能绕过校验', () async {
    final service = AppFavoritesService();
    final corrupt = (await service.createFolder('音乐'))!;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_favorites.items_v1.${corrupt.id}', '[broken');
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    await expectLater(service.importBackup(sample()), throwsFormatException);
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    final bad = AppFavoritesBackup(
      folders: [folder('', '无效')],
      items: {},
      exportedAt: collectedAt,
    );
    await expectLater(service.importBackup(bad), throwsFormatException);
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
  });

  for (final throws in [false, true]) {
    test('写入${throws ? '异常' : '拒绝'}时恢复此前写入和缓存，并可正常重试', () async {
      final initial = AppFavoritesService();
      final local = (await initial.createFolder('学习'))!;
      await initial.addItem(item(local.id, 'BV1GJ411x7h7', title: '保留本机'));
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      final failing = FailingPreferences(prefs, failOnWrite: 3, throws: throws);
      final service = AppFavoritesService(
        preferencesLoader: () async => failing,
      );
      await expectLater(service.importBackup(sample()), throwsStateError);
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
      await prefs.reload();
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
      expect((await service.importBackup(sample())).importedItems, 2);
    });
  }

  test('跨服务的并发导入与新建均被保留，导出读取完整快照', () async {
    final first = AppFavoritesService();
    final second = AppFavoritesService();
    await Future.wait([
      first.importBackup(sample()),
      second.createFolder('并发新建'),
    ]);
    final backup = await first.exportBackup();
    expect(backup.folders, hasLength(4));
    expect(backup.itemCount, 3);
  });

  test('兼容选择器的内存字节、云文件流和 macOS 本机路径', () async {
    const files = AppFavoritesFileService();
    final bytes = sample().toBytes();
    final directory = await Directory.systemTemp.createTemp('favorites-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/中文收藏.json';
    await File(path).writeAsBytes(bytes);
    for (final file in [
      PlatformFile(name: 'backup.json', size: bytes.length, bytes: bytes),
      PlatformFile(
        name: 'backup.json',
        size: 0,
        readStream: Stream.fromIterable([
          bytes.sublist(0, 10),
          bytes.sublist(10),
        ]),
      ),
      PlatformFile(name: '中文收藏.json', size: bytes.length, path: path),
    ]) {
      expect(
        AppFavoritesBackup.fromBytes(await files.readFile(file)).itemCount,
        3,
      );
    }
    await expectLater(
      files.readFile(PlatformFile(name: 'missing.json', size: 0)),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('文件大小检查覆盖未知大小的流，防止一次加载过大文件', () async {
    const files = AppFavoritesFileService();
    await expectLater(
      files.readFile(
        PlatformFile(name: 'large.json', size: AppFavoritesBackup.maxBytes + 1),
      ),
      throwsFormatException,
    );
    await expectLater(
      files.readFile(
        PlatformFile(
          name: 'large.json',
          size: 0,
          readStream: Stream.value(Uint8List(AppFavoritesBackup.maxBytes + 1)),
        ),
      ),
      throwsFormatException,
    );
  });

  test('导出将完整 UTF-8 字节交给系统保存，取消不误报成功', () async {
    final previous = FilePickerPlatform.instance;
    final picker = RecordingFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final directory = await Directory.systemTemp.createTemp('favorites-save-');
    addTearDown(() => directory.delete(recursive: true));
    const files = AppFavoritesFileService();
    expect(await files.saveBackup(sample()), isFalse);
    picker.destination = '${directory.path}/备份.json';
    expect(await files.saveBackup(sample()), isTrue);
    expect(
      AppFavoritesBackup.fromBytes(
        await File(picker.destination!).readAsBytes(),
      ).itemCount,
      3,
    );
    expect(picker.proposedName, endsWith('.json'));
    expect(picker.proposedName, isNot(contains(':')));
    expect(picker.locked, isTrue);
  });
}
