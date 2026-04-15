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

  /// Font size used for the invisible text overlay.
  ///
  /// Kept small enough that the text wraps within typical A4 page dimensions
  /// without overflowing, while still being indexed by PDF search engines.
  static const _invisibleTextFontSize = 12.0;

  /// Computes the per-axis scale factors used to map OCR bounding-box
  /// coordinates from image-pixel space to PDF-point space.
  ///
  /// This mirrors the layout produced by [pw.BoxFit.fill]: the image is
  /// stretched independently on each axis to fill the page exactly, so
  /// independent X and Y scale factors are required and there are no
  /// centering offsets.
  ///
  /// Returns a record of `(scaleX, scaleY)`.
  static ({double scaleX, double scaleY})
      computePageMapping({
    required double imageWidth,
    required double imageHeight,
    required double pageWidth,
    required double pageHeight,
  }) {
    final scaleX =
        (imageWidth > 0) ? pageWidth / imageWidth : 1.0;
    final scaleY =
        (imageHeight > 0) ? pageHeight / imageHeight : 1.0;
    return (scaleX: scaleX, scaleY: scaleY);
  }

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

      // Use A4 page format, choosing landscape for landscape images so the
      // scan fills the page without distortion.
      final pageFormat =
          imgWidth > imgHeight ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

      // Compute the per-axis scale factors matching BoxFit.fill behavior.
      // The image is stretched independently on each axis to fill the page,
      // so we use separate X and Y scale factors (and no centering offsets)
      // to map OCR bounding boxes from image-pixel space to PDF-point space.
      final mapping = computePageMapping(
        imageWidth: imgWidth,
        imageHeight: imgHeight,
        pageWidth: pageFormat.width,
        pageHeight: pageFormat.height,
      );
      final scaleX = mapping.scaleX;
      final scaleY = mapping.scaleY;

      // Get the page's OCR blocks (or empty if no blocks for this page)
      final pageBlocks =
          i < textBlocks.length ? textBlocks[i] : <OcrTextBlock>[];

      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (pw.Context context) {
            return pw.Stack(
              fit: pw.StackFit.expand,
              children: [
                // Full-page scanned image as background
                pw.Positioned.fill(
                  child: pw.Image(image, fit: pw.BoxFit.fill),
                ),
                // Invisible OCR text overlay for searchability.
                // Uses element-level (word) bounding boxes with FittedBox
                // stretching to ensure text highlight positions match exactly.
                ...pageBlocks.expand((block) {
                  return block.lines.expand((line) {
                    return line.elements
                        .where(
                          (element) =>
                              element.text.isNotEmpty &&
                              element.width > 0 &&
                              element.height > 0,
                        )
                        .map((element) {
                      final mappedLeft = element.left * scaleX;
                      final mappedTop = element.top * scaleY;
                      final mappedWidth = element.width * scaleX;
                      final mappedHeight = element.height * scaleY;

                      return pw.Positioned(
                        left: mappedLeft,
                        top: mappedTop,
                        child: pw.SizedBox(
                          width: mappedWidth,
                          height: mappedHeight,
                          child: pw.FittedBox(
                            fit: pw.BoxFit.fill,
                            child: pw.Text(
                              element.text,
                              style: pw.TextStyle(
                                renderingMode:
                                    PdfTextRenderingMode.invisible,
                                fontSize: _invisibleTextFontSize,
                              ),
                            ),
                          ),
                        ),
                      );
                    });
                  });
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

  /// Regenerates a searchable PDF from scanned images and plain (edited) text.
  ///
  /// Used when the user has manually edited the OCR text. Because the original
  /// word-level bounding boxes are no longer available, the edited text for
  /// each page is placed as a single invisible text block that covers the page.
  /// The text is still fully searchable and copy-pasteable in PDF viewers.
  ///
  /// [imagePaths] - The original image file paths (one per page).
  /// [combinedText] - The full edited OCR text with page-break delimiters.
  /// [title] - The document title for PDF metadata.
  ///
  /// Returns the file path to the regenerated PDF.
  Future<String> regeneratePdfFromPlainText({
    required List<String> imagePaths,
    required String combinedText,
    required String title,
  }) async {
    const pageBreakDelimiter = '\n\n--- Page Break ---\n\n';
    final pageTexts = combinedText.split(pageBreakDelimiter);

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

      final decodedImage = await _decodeImageDimensions(imageBytes);
      final imgWidth = decodedImage.width.toDouble();
      final imgHeight = decodedImage.height.toDouble();

      final pageFormat =
          imgWidth > imgHeight ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

      final pageText = i < pageTexts.length ? pageTexts[i].trim() : '';

      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (pw.Context context) {
            return pw.Stack(
              fit: pw.StackFit.expand,
              children: [
                // Full-page scanned image as background
                pw.Positioned.fill(
                  child: pw.Image(image, fit: pw.BoxFit.fill),
                ),
                // Invisible edited text overlay for searchability.
                // Placed as a single block since word-level positions are
                // not available after manual editing.
                if (pageText.isNotEmpty)
                  pw.Positioned(
                    left: 0,
                    top: 0,
                    child: pw.SizedBox(
                      width: pageFormat.width,
                      height: pageFormat.height,
                      child: pw.Text(
                        pageText,
                        style: pw.TextStyle(
                          renderingMode: PdfTextRenderingMode.invisible,
                          fontSize: _invisibleTextFontSize,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
    }

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
