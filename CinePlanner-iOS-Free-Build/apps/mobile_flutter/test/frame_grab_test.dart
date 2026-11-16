import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:cineplanner/domain/frame_grab.dart';

void main() {
  test(
    'original stays byte-exact while a bounded JPEG preview is generated',
    () {
      final source = img.Image(width: 1600, height: 900);
      img.fill(source, color: img.ColorRgb8(80, 140, 220));
      final bytes = Uint8List.fromList(img.encodePng(source));
      final result = prepareFrame(bytes);
      expect(result.width, 1600);
      expect(result.height, 900);
      expect(result.mime, 'image/png');
      expect(result.original, bytes);
      expect(result.checksum, sha256.convert(bytes).toString());
      final preview = img.decodeJpg(result.preview)!;
      expect(preview.width, 1280);
      expect(preview.height, 720);
      expect(() => result.original[0] = 0, throwsUnsupportedError);
    },
  );
  test('invalid and unsupported image data are rejected', () {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([0xff, 0xd8, 0xff, 0]),
    ]) {
      expect(() => prepareFrame(bytes), throwsA(anything));
    }
  });
}
