import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// A 2D point representing a corner coordinate in image-pixel space.
class Corner {
  /// The x-coordinate (horizontal position) in pixels.
  final double x;

  /// The y-coordinate (vertical position) in pixels.
  final double y;

  const Corner(this.x, this.y);

  @override
  String toString() => 'Corner($x, $y)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Corner && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// The four corners of a detected document, in image-pixel coordinates.
///
/// Corners are expected in the following layout:
/// ```
/// topLeft -------- topRight
///    |                 |
///    |                 |
/// bottomLeft -- bottomRight
/// ```
class DocumentCorners {
  final Corner topLeft;
  final Corner topRight;
  final Corner bottomLeft;
  final Corner bottomRight;

  const DocumentCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomLeft,
    required this.bottomRight,
  });

  /// The computed width of the output rectangle, derived from the maximum
  /// horizontal distance between the left and right edges.
  double get outputWidth {
    final topWidth = _distance(topLeft, topRight);
    final bottomWidth = _distance(bottomLeft, bottomRight);
    return math.max(topWidth, bottomWidth);
  }

  /// The computed height of the output rectangle, derived from the maximum
  /// vertical distance between the top and bottom edges.
  double get outputHeight {
    final leftHeight = _distance(topLeft, bottomLeft);
    final rightHeight = _distance(topRight, bottomRight);
    return math.max(leftHeight, rightHeight);
  }

  @override
  String toString() =>
      'DocumentCorners(tl: $topLeft, tr: $topRight, bl: $bottomLeft, br: $bottomRight)';

  static double _distance(Corner a, Corner b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// Data payload sent to the background isolate for perspective warping.
class _WarpPayload {
  final Uint8List imageBytes;
  final DocumentCorners corners;

  const _WarpPayload(this.imageBytes, this.corners);
}

/// Top-level function for running perspective warping in a background isolate.
///
/// Takes a [_WarpPayload] containing the raw image bytes and corner
/// coordinates, performs the perspective warp via [copyRectify], and
/// returns the warped image as PNG-encoded bytes.
///
/// Must be a top-level function so it can be passed to [compute].
Uint8List _warpImageIsolate(_WarpPayload payload) {
  final original = img.decodeImage(payload.imageBytes);
  if (original == null) {
    throw Exception('Failed to decode image in perspective warp isolate');
  }

  final warped = PerspectiveService.warpImage(original, payload.corners);
  return Uint8List.fromList(img.encodePng(warped));
}

/// Service responsible for perspective transformation (image warping).
///
/// When a document is photographed at an angle, the four detected corners
/// are used to warp the image into a perfect rectangular top-down view.
///
/// Uses the `image` package's [img.copyRectify] for the perspective
/// transformation, which maps an arbitrary quadrilateral to a rectangle
/// using bilinear interpolation.
class PerspectiveService {
  static const _uuid = Uuid();

  /// Maximum multiplier for the output image dimensions relative to the input.
  ///
  /// Limits the warped output to at most 2× the source dimension on each axis
  /// to prevent memory issues from degenerate corner placements that would
  /// produce an unreasonably large output image.
  static const int _maxOutputScaleFactor = 2;

  /// Performs a perspective warp on the given [image] using [corners].
  ///
  /// Maps the quadrilateral defined by the four [corners] to a rectangle
  /// whose dimensions are derived from the longest edges of the quad.
  /// This produces a top-down rectangular view of the document.
  ///
  /// The output image dimensions are computed from the corner positions:
  /// - Width = max(distance(topLeft, topRight), distance(bottomLeft, bottomRight))
  /// - Height = max(distance(topLeft, bottomLeft), distance(topRight, bottomRight))
  static img.Image warpImage(img.Image image, DocumentCorners corners) {
    final outputWidth = corners.outputWidth
        .round()
        .clamp(1, image.width * _maxOutputScaleFactor);
    final outputHeight = corners.outputHeight
        .round()
        .clamp(1, image.height * _maxOutputScaleFactor);

    final destination = img.Image(
      width: outputWidth,
      height: outputHeight,
    );

    return img.copyRectify(
      image,
      topLeft: img.Point(corners.topLeft.x, corners.topLeft.y),
      topRight: img.Point(corners.topRight.x, corners.topRight.y),
      bottomLeft: img.Point(corners.bottomLeft.x, corners.bottomLeft.y),
      bottomRight: img.Point(corners.bottomRight.x, corners.bottomRight.y),
      toImage: destination,
    );
  }

  /// Warps a document image file using the given [corners] and saves the
  /// result to a new file.
  ///
  /// The CPU-intensive perspective transformation is offloaded to a
  /// background isolate via [compute] to keep the UI responsive.
  ///
  /// Returns the file path to the warped image.
  Future<String> warpImageFile(
    String imagePath,
    DocumentCorners corners,
  ) async {
    try {
      final bytes = await File(imagePath).readAsBytes();

      // Offload CPU-intensive warp to a background isolate
      final warpedBytes = await compute(
        _warpImageIsolate,
        _WarpPayload(bytes, corners),
      );

      // Save the warped image
      final dir = await getApplicationDocumentsDirectory();
      final warpedPath = '${dir.path}/warped_${_uuid.v4()}.png';
      await File(warpedPath).writeAsBytes(warpedBytes);

      return warpedPath;
    } catch (e) {
      throw PerspectiveException('Failed to warp image: $e');
    }
  }

  /// Orders an unordered list of four corner points into the canonical
  /// [DocumentCorners] layout: top-left, top-right, bottom-left, bottom-right.
  ///
  /// The algorithm:
  /// 1. Sort by the sum (x + y): smallest sum → top-left, largest → bottom-right.
  /// 2. Sort by the difference (y - x): smallest → top-right, largest → bottom-left.
  ///
  /// This approach works reliably for document quadrilaterals where the
  /// document is roughly upright (not rotated more than ~45°).
  static DocumentCorners orderCorners(List<Corner> points) {
    if (points.length != 4) {
      throw PerspectiveException(
        'Expected exactly 4 corner points, got ${points.length}',
      );
    }

    // Sort by sum of coordinates (x + y)
    final sorted = List<Corner>.from(points)
      ..sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));

    // Smallest sum = top-left, largest sum = bottom-right
    final topLeft = sorted.first;
    final bottomRight = sorted.last;

    // Of the two middle points, the one with smaller (y - x) is top-right,
    // the one with larger (y - x) is bottom-left
    final middle = [sorted[1], sorted[2]];
    middle.sort((a, b) => (a.y - a.x).compareTo(b.y - b.x));
    final topRight = middle.first;
    final bottomLeft = middle.last;

    return DocumentCorners(
      topLeft: topLeft,
      topRight: topRight,
      bottomLeft: bottomLeft,
      bottomRight: bottomRight,
    );
  }

  /// Maps corner coordinates from a display/preview resolution to the
  /// original image resolution.
  ///
  /// When corners are detected in a downscaled preview, they must be
  /// scaled back to the original image dimensions before warping.
  ///
  /// [corners] - Detected corners in display-resolution coordinates.
  /// [displayWidth] - Width of the display/preview image.
  /// [displayHeight] - Height of the display/preview image.
  /// [imageWidth] - Width of the original full-resolution image.
  /// [imageHeight] - Height of the original full-resolution image.
  static DocumentCorners mapCornersToImageResolution({
    required DocumentCorners corners,
    required double displayWidth,
    required double displayHeight,
    required double imageWidth,
    required double imageHeight,
  }) {
    final scaleX = imageWidth / displayWidth;
    final scaleY = imageHeight / displayHeight;

    Corner scale(Corner c) => Corner(c.x * scaleX, c.y * scaleY);

    return DocumentCorners(
      topLeft: scale(corners.topLeft),
      topRight: scale(corners.topRight),
      bottomLeft: scale(corners.bottomLeft),
      bottomRight: scale(corners.bottomRight),
    );
  }
}

/// Exception thrown by [PerspectiveService] operations.
class PerspectiveException implements Exception {
  final String message;
  const PerspectiveException(this.message);

  @override
  String toString() => 'PerspectiveException: $message';
}
