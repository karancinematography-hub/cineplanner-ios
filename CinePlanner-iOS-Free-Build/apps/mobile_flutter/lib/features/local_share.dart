import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

/// User-selected exports are intentionally unencrypted and app-private until
/// shared. Opaque generated filenames prevent record IDs becoming file paths.
Future<void> shareExportBytes(
  List<int> bytes, {
  required String extension,
  required String mime,
  required String subject,
}) async {
  if (!{'svg', 'pdf', 'cinepack', 'jpg', 'png'}.contains(extension)) {
    throw ArgumentError('Unsupported export format');
  }
  final directory = Directory(
    p.join((await getTemporaryDirectory()).path, 'cineplanner-exports'),
  );
  await directory.create(recursive: true);
  final cutoff = DateTime.now().subtract(const Duration(hours: 24));
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is File && (await entry.stat()).modified.isBefore(cutoff)) {
      await entry.delete();
    }
  }
  final file = File(p.join(directory.path, '${const Uuid().v4()}.$extension'));
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: mime)],
      subject: subject,
    ),
  );
}
