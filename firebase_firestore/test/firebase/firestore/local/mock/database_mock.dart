// File created by
// Lung Razvan <long1eu>
// on 29/09/2018

import 'dart:async';
import 'dart:io';

import 'package:firebase_firestore/src/firebase/firestore/util/database_impl.dart';
import 'package:sqlite/sqlite.dart' as sql;

class DatabaseMock extends Database {
  sql.Database database;
  File path;

  DatabaseMock._(this.database, this.path);

  static Future<DatabaseMock> create(String name,
      {int version,
      OnConfigure onConfigure,
      OnCreate onCreate,
      OnVersionChange onUpgrade,
      OnVersionChange onDowngrade,
      OnOpen onOpen}) async {
    version ??= 1;

    final File path = File('${Directory.current.path}/build/test/$name');
    final bool callOnCreate = !path.existsSync();
    path.createSync(recursive: true);

    final sql.Database database = sql.Database(path.path);
    final DatabaseMock mock = DatabaseMock._(database, path);

    await onConfigure?.call(mock);
    if (callOnCreate) {
      await onCreate?.call(mock, version);
      await database.execute('PRAGMA user_version = $version;');
    } else {
      final List<sql.Row> row =
          await database.query('PRAGMA user_version;').toList();
      final int currentVersion = row.first.toMap().values.first;

      if (currentVersion < version) {
        await onUpgrade?.call(mock, currentVersion, version);
        await database.execute('PRAGMA user_version = $version;');
      }

      if (currentVersion > version) {
        await database.execute('PRAGMA user_version = $version;');
        await onDowngrade?.call(mock, currentVersion, version);
      }
    }

    await onOpen?.call(mock);
    return mock;
  }

  @override
  Future<int> delete(String statement, [List<dynamic> arguments]) {
    return database.execute(statement, params: arguments ?? <dynamic>[]);
  }

  @override
  Future<void> execute(String statement, [List<dynamic> arguments]) async {
    await database.execute(statement, params: arguments ?? <dynamic>[]);
  }

  @override
  Future<List<Map<String, dynamic>>> query(String statement,
      [List<void> arguments]) async {
    return database
        .query(statement, params: arguments ?? <dynamic>[])
        .toList()
        .then(
          (List<sql.Row> rows) =>
              rows.map((sql.Row row) => row.toMap()).toList(),
        );
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor) action,
      {bool exclusive}) async {
    final Completer<T> completer = Completer<T>();
    try {
      database.transaction(() async {
        final T result = await action(this);
        completer.complete(result);
      });
    } catch (e) {
      print(e);
      completer.complete(null);
    }
    return completer.future;
  }

  @override
  void close() {
    database.close();
    path.renameSync('${path.path}_');
  }
}
