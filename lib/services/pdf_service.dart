import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';

import 'scanner_service.dart';

/// Service responsible for generating searchable PDF documents.
///
/// Creates PDFs where the scanned image is displayed as the page background
/// and the OCR text is placed invisibly over the corresponding regions.
/// This allows the PDF to be visually identical to the scan while being
/// fully text-searchable and copy-pasteable.
class PdfService {
  static const _uuid = Uuid();

  /// Generates a searchable PDF from scanned images and their OCR text blocks.
  ///
  /// Each page in the PDF contains:
  /// - The scanned image as the full-page background
  /// - Invisible (transparent) text overlaid at the exact positions where
  ///   the OCR engine detected text
  ///
  /// [imagePaths] - The original or enhanced image file paths (one per page).
  /// [textBlocks] - The OCR text blocks per page, with bounding box positions.
  /// [title] - The document title for PDF metadata.
  ///
  /// Returns the file path to the generated PDF.
  Future<String> generateSearchablePdf({
    required List<String> imagePaths,
    required List<List<OcrTextBlock>> textBlocks,
    required String title,
  }) async {
    final pdf = pw.Document(
      title: title,
      author: 'FluxScan',
      creator: 'FluxScan - Privacy-First Document Scanner',
      producer: 'FluxScan',
    );

    for (var i = 0; i < imagePaths.length; i++) {
      final imageFile = File(imagePaths[i]);
      final imageBytes = await imageFile.readAsBytes();
      final image = pw.MemoryImage(imageBytes);

      // Get the image dimensions to calculate scaling
      final decodedImage =
          await _decodeImageDimensions(imageBytes);
      final imgWidth = decodedImage.width.toDouble();
      final imgHeight = decodedImage.height.toDouble();

      // Use A4 page format
      const pageFormat = PdfPageFormat.a4;

      // Get the page's OCR blocks (or empty if no blocks for this page)
      final pageBlocks =
          i < textBlocks.length ? textBlocks[i] : <OcrTextBlock>[];

      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (pw.Context context) {
            return pw.Stack(
              children: [
                // Full-page scanned image as background
                pw.Positioned.fill(
                  child: pw.Image(image, fit: pw.BoxFit.contain),
                ),
                // Invisible OCR text overlay for searchability
                ...pageBlocks.map((block) {
                  // Scale block coordinates from image space to page space
                  final scaleX = imgWidth > 0
                      ? pageFormat.width / imgWidth
                      : 1.0;
                  final scaleY = imgHeight > 0
                      ? pageFormat.height / imgHeight
                      : 1.0;

                  return pw.Positioned(
                    left: block.left * scaleX,
                    top: block.top * scaleY,
                    width: block.width * scaleX,
                    height: block.height * scaleY,
                    child: pw.Text(
                      block.text,
                      style: pw.TextStyle(
                        // Transparent text: invisible but searchable
                        color: PdfColor.fromInt(0x00000000),
                        fontSize: (block.height * scaleY * 0.8)
                            .clamp(4.0, 20.0),
                      ),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      );
    }

    // Save the PDF to the documents directory
    final dir = await getApplicationDocumentsDirectory();
    final pdfPath = '${dir.path}/scan_${_uuid.v4()}.pdf';
    final file = File(pdfPath);
    await file.writeAsBytes(await pdf.save());

    return pdfPath;
  }

  /// Decodes only the dimensions of an image without fully decoding pixels.
  Future<_ImageDimensions> _decodeImageDimensions(
    List<int> bytes,
  ) async {
    // Use the image package for dimension detection
    final image =
        await Future.value(_decodeDimensions(bytes));
    return image;
  }

  /// Synchronously decodes image dimensions from bytes.
  _ImageDimensions _decodeDimensions(List<int> bytes) {
    // Attempt to read PNG dimensions from header
    if (bytes.length > 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50) {
      // PNG: width at offset 16, height at offset 20 (big-endian)
      final width = (bytes[16] << 24) |
          (bytes[17] << 16) |
          (bytes[18] << 8) |
          bytes[19];
      final height = (bytes[20] << 24) |
          (bytes[21] << 16) |
          (bytes[22] << 8) |
          bytes[23];
      return _ImageDimensions(width, height);
    }

    // Attempt to read JPEG dimensions
    if (bytes.length > 2 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8) {
      return _readJpegDimensions(bytes);
    }

    // Fallback: assume A4-proportioned dimensions
    return const _ImageDimensions(2480, 3508);
  }

  /// Reads JPEG image dimensions from SOF markers.
  _ImageDimensions _readJpegDimensions(List<int> bytes) {
    var offset = 2;
    while (offset < bytes.length - 1) {
      if (bytes[offset] != 0xFF) break;
      final marker = bytes[offset + 1];

      // SOF0 through SOF2 contain dimensions
      if (marker >= 0xC0 && marker <= 0xC2) {
        if (offset + 9 < bytes.length) {
          final height = (bytes[offset + 5] << 8) | bytes[offset + 6];
          final width = (bytes[offset + 7] << 8) | bytes[offset + 8];
          return _ImageDimensions(width, height);
        }
      }

      // Skip to next marker
      if (offset + 3 < bytes.length) {
        final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
        offset += 2 + length;
      } else {
        break;
      }
    }

    // Fallback
    return const _ImageDimensions(2480, 3508);
  }
}

class _ImageDimensions {
  final int width;
  final int height;
  const _ImageDimensions(this.width, this.height);
}
