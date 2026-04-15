import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

/// Service for importing existing (non-searchable) PDFs.
///
/// Presents a system file picker so the user can select a PDF, then
/// rasterises each page into a high-resolution PNG file. The resulting
/// image paths can be fed directly into [ScannerService.processImages],
/// which runs the standard ML Kit OCR pipeline and ultimately produces
/// a new, fully searchable PDF.
class PdfImportService {
  static const _uuid = Uuid();

  /// Scale factor applied when rendering PDF pages to images.
  ///
  /// PDF page dimensions are measured in points (1 pt = 1/72 inch).
  /// Multiplying by 3.0 gives ~216 DPI, which ensures high OCR quality
  /// while keeping memory usage reasonable.
  static const _renderScale = 3.0;

  /// Opens the system file picker filtered to PDF files.
  ///
  /// Returns the absolute path of the selected PDF, or `null` if the
  /// user cancels without picking a file.
  Future<String?> pickPdfFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    return result?.files.single.path;
  }

  /// Renders every page of the PDF at [pdfPath] to a temporary PNG file.
  ///
  /// Each page is rasterised at [_renderScale] × its native point size,
  /// yielding approximately 144 DPI images. The RGBA pixel data returned
  /// by pdfrx is converted to PNG using the `image` package and written
  /// to the system temporary directory.
  ///
  /// Returns the list of temporary PNG file paths in page order.
  /// The caller is responsible for deleting these files when they are no
  /// longer needed (see [HomeScreen._importPdf]).
  Future<List<String>> renderPagesToImages(String pdfPath) async {
    final document = await PdfDocument.openFile(pdfPath);
    final tempDir = await getTemporaryDirectory();
    final imagePaths = <String>[];

    try {
      for (var i = 0; i < document.pages.length; i++) {
        final page = document.pages[i];
        final width = (page.width * _renderScale).toInt();
        final height = (page.height * _renderScale).toInt();

        final pdfImage = await page.render(width: width, height: height);
        if (pdfImage == null) continue;

        try {
          // pdfrx returns raw RGBA pixels; convert to PNG via the image package.
          final imgData = img.Image.fromBytes(
            width: pdfImage.width,
            height: pdfImage.height,
            bytes: pdfImage.pixels.buffer,
            format: img.Format.uint8,
            numChannels: 4,
          );
          final pngBytes = img.encodePng(imgData);

          final imagePath =
              '${tempDir.path}/import_page_${i + 1}_${_uuid.v4()}.png';
          await File(imagePath).writeAsBytes(pngBytes);
          imagePaths.add(imagePath);
        } finally {
          pdfImage.dispose();
        }
      }
    } finally {
      await document.dispose();
    }

    return imagePaths;
  }
}
