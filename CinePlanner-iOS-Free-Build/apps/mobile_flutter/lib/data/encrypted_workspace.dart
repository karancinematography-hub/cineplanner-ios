import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'workspace_repository.dart';

Future<WorkspaceRepository> openEncryptedWorkspace() async {
  const secrets = FlutterSecureStorage();
  final path = p.join(await getDatabasesPath(), 'cineplanner-v1.db');
  var key = await secrets.read(key: 'workspace-key-v1');
  if (key == null) {
    if (await File(path).exists()) {
      throw StateError(
        'Workspace key unavailable. Restore a verified backup; existing data has not been replaced.',
      );
    }
    final random = Random.secure();
    key = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    await secrets.write(key: 'workspace-key-v1', value: key);
  }
  var deviceId = await secrets.read(key: 'device-id');
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await secrets.write(key: 'device-id', value: deviceId);
  }
  final db = await openDatabase(
    path,
    password: key,
    version: WorkspaceRepository.schemaVersion,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.execute('PRAGMA synchronous = FULL');
    },
    onCreate: WorkspaceRepository.migrate,
    onUpgrade: WorkspaceRepository.upgrade,
  );
  return WorkspaceRepository(
    db,
    deviceId: deviceId,
    actorId: 'local:$deviceId',
  );
}
