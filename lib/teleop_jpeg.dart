import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as im;

/// 将 YUV420 帧转为彩色 JPEG。
/// 说明：
/// - 使用 CPU 转换，适合 demo 与中低分辨率实时推流。
/// - 如需更低延迟/更高帧率，建议后续切到原生硬编或 WebRTC。
Uint8List? yuv420ToJpegColor(
  CameraImage image, {
  int quality = 65,
  int? maxWidth,
}) {
  if (image.planes.length < 3) return null;

  final int width = image.width;
  final int height = image.height;
  final Plane yPlane = image.planes[0];
  final Plane uPlane = image.planes[1];
  final Plane vPlane = image.planes[2];

  final int yRowStride = yPlane.bytesPerRow;
  final int uRowStride = uPlane.bytesPerRow;
  final int vRowStride = vPlane.bytesPerRow;
  final int uPixelStride = uPlane.bytesPerPixel ?? 1;
  final int vPixelStride = vPlane.bytesPerPixel ?? 1;
  final Uint8List yBytes = yPlane.bytes;
  final Uint8List uBytes = uPlane.bytes;
  final Uint8List vBytes = vPlane.bytes;

  im.Image out = im.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    final int uvRow = y >> 1;
    for (int x = 0; x < width; x++) {
      final int uvCol = x >> 1;

      final int yIndex = y * yRowStride + x;
      final int uIndex = uvRow * uRowStride + uvCol * uPixelStride;
      final int vIndex = uvRow * vRowStride + uvCol * vPixelStride;

      final int yy = yBytes[yIndex] & 0xff;
      final int uu = (uBytes[uIndex] & 0xff) - 128;
      final int vv = (vBytes[vIndex] & 0xff) - 128;

      int r = (yy + 1.402 * vv).round();
      int g = (yy - 0.344136 * uu - 0.714136 * vv).round();
      int b = (yy + 1.772 * uu).round();

      if (r < 0) r = 0;
      if (g < 0) g = 0;
      if (b < 0) b = 0;
      if (r > 255) r = 255;
      if (g > 255) g = 255;
      if (b > 255) b = 255;

      out.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  if (maxWidth != null && width > maxWidth) {
    out = im.copyResize(out, width: maxWidth);
  }
  return Uint8List.fromList(im.encodeJpg(out, quality: quality));
}
