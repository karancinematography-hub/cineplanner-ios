import 'dart:typed_data';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

class PreparedFrame {
  final Uint8List original, preview;
  final String mime, checksum, previewChecksum;
  final int width, height;
  PreparedFrame({
    required Uint8List original,
    required Uint8List preview,
    required this.mime,
    required this.width,
    required this.height,
  }) : original = Uint8List.fromList(original).asUnmodifiableView(),
       preview = Uint8List.fromList(preview).asUnmodifiableView(),
       checksum = sha256.convert(original).toString(),
       previewChecksum = sha256.convert(preview).toString();
}

/// Runs in an isolate. Bound compressed bytes and dimensions before decoding.
/// JPEG/PNG originals are preserved byte-for-byte; previews omit EXIF metadata.
PreparedFrame prepareFrame(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
    throw const FormatException('Use a JPEG or PNG smaller than 25 MB.');
  }
  final jpeg =
      bytes.length > 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;
  final png =
      bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47;
  if (!jpeg && !png) {
    throw const FormatException('Supported frame grabs are JPEG and PNG.');
  }
  final decoder = jpeg ? img.JpegDecoder() : img.PngDecoder();
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 24 * 1000 * 1000 ||
      info.numFrames != 1) {
    throw const FormatException(
      'Use a single-frame image with at most 24 megapixels.',
    );
  }
  final decoded = decoder.decodeFrame(0);
  if (decoded == null) {
    throw const FormatException('The frame grab could not be decoded.');
  }
  final oriented = img.bakeOrientation(decoded);
  final scale = math.min(1.0, 1280 / math.max(oriented.width, oriented.height));
  final resized = img.copyResize(
    oriented,
    width: math.max(1, (oriented.width * scale).round()),
    height: math.max(1, (oriented.height * scale).round()),
  );
  final clean = img.Image(
    width: resized.width,
    height: resized.height,
    numChannels: 3,
  );
  img.fill(clean, color: img.ColorRgb8(0, 0, 0));
  img.compositeImage(clean, resized);
  return PreparedFrame(
    original: bytes,
    preview: Uint8List.fromList(img.encodeJpg(clean, quality: 80)),
    mime: jpeg ? 'image/jpeg' : 'image/png',
    width: oriented.width,
    height: oriented.height,
  );
}

class FrameGrab {
  final String assetId, shotId, checksum, mime, createdBy;
  final int width, height;
  final DateTime createdAt;
  final Uint8List preview;
  FrameGrab({
    required this.assetId,
    required this.shotId,
    required this.checksum,
    required this.mime,
    required this.createdBy,
    required this.width,
    required this.height,
    required this.createdAt,
    required Uint8List preview,
  }) : preview = Uint8List.fromList(preview).asUnmodifiableView();
}
