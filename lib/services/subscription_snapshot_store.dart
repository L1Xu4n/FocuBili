import 'dart:async';
import 'package:sqflite/sqflite.dart';

/// Mutations reload the latest snapshot and commit with an atomic SQL CAS.
/// The callback can run again on contention: it must have no external effects.
/// No Dart-held SQLite transaction survives a stopped headless engine.
abstract interface class SubscriptionSnapshotStore {
  Future<String?> read();
  Future<String?> recover(bool Function(String) validate);
  Future<T> transact<T>(
    FutureOr<T> Function(String? current, void Function(String) save) action,
  );
}

class SqliteSubscriptionSnapshotStore implements SubscriptionSnapshotStore {
  SqliteSubscriptionSnapshotStore({this.databaseName = 'subscriptions_v2.db'});
  final String databaseName;
  Future<Database>? _database;
  Future<Database> get _db => _database ??= _open();
  Future<Database> _open() async {
    // Independent handles avoid sqflite's cross-engine recovered-transaction
    // behavior. Schema creation itself is one atomic native SQLite statement.
    final db = await openDatabase(
      '${await getDatabasesPath()}/$databaseName',
      singleInstance: false,
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK (id = 1), value TEXT NOT NULL, backup TEXT, quarantine TEXT)',
    );
    return db;
  }

  Future<void> close() async {
    try {
      if (_database != null) await (await _database!).close();
    } catch (_) {
      // A failed open has no usable handle; disposal must not crash the app.
    }
  }

  @override
  Future<String?> read() async {
    final rows = await (await _db).query(
      'snapshot',
      columns: ['value'],
      where: 'id = 1',
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  @override
  Future<String?> recover(bool Function(String) validate) async {
    final db = await _db;
    for (var attempt = 0; attempt < 40; attempt++) {
      final rows = await db.query(
        'snapshot',
        columns: ['value', 'backup'],
        where: 'id = 1',
      );
      if (rows.isEmpty) return null;
      final current = rows.single['value'] as String;
      if (validate(current)) return current;
      final backup = rows.single['backup'] as String?;
      if (backup == null || !validate(backup)) return null;
      final changed = await db.rawUpdate(
        'UPDATE snapshot SET value = ?, quarantine = ? WHERE id = 1 AND value = ? AND backup = ?',
        [backup, current, current, backup],
      );
      if (changed == 1) return backup;
    }
    throw StateError('Subscription snapshot contention');
  }

  @override
  Future<T> transact<T>(
    FutureOr<T> Function(String? current, void Function(String) save) action,
  ) async {
    final db = await _db;
    for (var attempt = 0; attempt < 40; attempt++) {
      final rows = await db.query(
        'snapshot',
        columns: ['value'],
        where: 'id = 1',
      );
      final current = rows.isEmpty ? null : rows.single['value'] as String;
      String? next;
      final result = await action(current, (value) => next = value);
      if (next == null || next == current) return result;
      if (current == null) {
        await db.rawInsert(
          'INSERT OR IGNORE INTO snapshot (id, value) VALUES (1, ?)',
          [next],
        );
        // rawInsert reports the last row id, even when ignored. Verify ownership
        // through a following read: identical initial snapshots are equivalent.
        if (await read() == next) return result;
      } else {
        final changed = await db.rawUpdate(
          'UPDATE snapshot SET value = ?, backup = ? WHERE id = 1 AND value = ?',
          [next, current, current],
        );
        if (changed == 1) return result;
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw StateError('Subscription snapshot contention');
  }
}
