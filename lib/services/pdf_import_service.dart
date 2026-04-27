import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:image/image.dart' as img;

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

import 'pdf_service.dart';
import 'scanner_service.dart';

/// Result returned by [PdfImportService.processPdf] or [PdfImportService.extractMetadata].
class PdfImportResult {
  /// Absolute paths to the rasterised PNG files, one per page, in order.
  final List<String> imagePaths;

  /// Original page dimensions in PDF points, one entry per page.
  final List<PdfPageDimension> pageDimensions;

  /// Optional extracted text blocks per page if digital extraction was used.
  final List<List<OcrTextBlock>>? textBlocks;

  /// The resolved pixel dimensions of each page (scaled by _renderScale).
  final List<ui.Size> imageSizes;

  const PdfImportResult({
    required this.imagePaths,
    required this.pageDimensions,
    this.textBlocks,
    required this.imageSizes,
  });
}

/// Service for importing existing PDFs with optional lazy rendering support.
class PdfImportService {
  static const _uuid = Uuid();

  /// Scale factor applied when rendering PDF pages to images.
  /// 3.0 gives ~216 DPI, ensuring high quality for viewing and OCR.
  static const _renderScale = 3.0;

  /// Opens the system file picker filtered to PDF files.
  Future<String?> pickPdfFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    return result?.files.single.path;
  }

  /// Opens a PDF and checks if it has a text layer.
  Future<({bool hasText, PdfDocument document})> openAndCheckText(String pdfPath) async {
    final document = await PdfDocument.openFile(pdfPath);
    bool hasText = false;
    for (final page in document.pages) {
      final text = await page.loadStructuredText();
      if (text != null && text.fragments.isNotEmpty) {
        hasText = true;
        break;
      }
    }
    return (hasText: hasText, document: document);
  }

  /// Renders all pages of a PDF to high-resolution PNG images.
  Future<PdfImportResult> processPdf(
    String pdfPath, {
    required void Function(double progress) onProgress,
  }) async {
    final document = await PdfDocument.openFile(pdfPath);
    final tempDir = await getTemporaryDirectory();
    final List<String> imagePaths = [];
    final List<PdfPageDimension> pageDimensions = [];
    final List<List<OcrTextBlock>> textBlocks = [];
    final List<ui.Size> imageSizes = [];

    try {
      for (var i = 0; i < document.pages.length; i++) {
        final page = document.pages[i];
        pageDimensions.add(PdfPageDimension(width: page.width, height: page.height));

        // 1. Render page with proper scaling
        final pdfImage = await page.render(
          width: (page.width * _renderScale).toInt(),
          height: (page.height * _renderScale).toInt(),
          fullWidth: page.width * _renderScale,
          fullHeight: page.height * _renderScale,
        );

        if (pdfImage != null) {
          // Use actual rendered dimensions
          imageSizes.add(ui.Size(pdfImage.width.toDouble(), pdfImage.height.toDouble()));

          // Encode PNG using the 'image' package
          final image = img.Image.fromBytes(
            width: pdfImage.width,
            height: pdfImage.height,
            bytes: pdfImage.pixels.buffer,
            format: img.Format.uint8,
            numChannels: 4,
          );
          
          final pngBytes = img.encodePng(image);
          
          final tempPath = '${tempDir.path}/page_${i + 1}_${_uuid.v4()}.png';
          await File(tempPath).writeAsBytes(pngBytes);
          imagePaths.add(tempPath);
          
          pdfImage.dispose();
        }

        // 2. Extract text layer
        final pageText = await page.loadStructuredText();
        textBlocks.add(_mapPdfTextToOcrBlocks(pageText, page.width, page.height));

        onProgress((i + 1) / document.pages.length);
      }
    } finally {
      await document.dispose();
    }

    return PdfImportResult(
      imagePaths: imagePaths,
      pageDimensions: pageDimensions,
      textBlocks: textBlocks,
      imageSizes: imageSizes,
    );
  }

  /// Renders a single page of a PDF to a PNG image.
  Future<String> renderPage(String pdfPath, int pageIndex) async {
    final document = await PdfDocument.openFile(pdfPath);
    final tempDir = await getTemporaryDirectory();
    
    try {
      if (pageIndex >= document.pages.length) {
        throw Exception('Page index out of bounds');
      }
      
      final page = document.pages[pageIndex];
      final pdfImage = await page.render(
        width: (page.width * _renderScale).toInt(),
        height: (page.height * _renderScale).toInt(),
        fullWidth: page.width * _renderScale,
        fullHeight: page.height * _renderScale,
      );

      if (pdfImage == null) throw Exception('Failed to render page');

      final image = img.Image.fromBytes(
        width: pdfImage.width,
        height: pdfImage.height,
        bytes: pdfImage.pixels.buffer,
        format: img.Format.uint8,
        numChannels: 4,
      );
      
      final pngBytes = img.encodePng(image);
      final tempPath = '${tempDir.path}/thumb_${pageIndex}_${_uuid.v4()}.png';
      await File(tempPath).writeAsBytes(pngBytes);
      
      pdfImage.dispose();
      return tempPath;
    } finally {
      await document.dispose();
    }
  }

  /// Only extracts text blocks and dimensions, without rendering images.
  Future<PdfImportResult> extractMetadata(String pdfPath) async {
    final document = await PdfDocument.openFile(pdfPath);
    final List<PdfPageDimension> pageDimensions = [];
    final List<List<OcrTextBlock>> textBlocks = [];
    final List<ui.Size> imageSizes = [];

    try {
      for (var i = 0; i < document.pages.length; i++) {
        final page = document.pages[i];
        pageDimensions.add(PdfPageDimension(width: page.width, height: page.height));
        imageSizes.add(ui.Size(page.width * _renderScale, page.height * _renderScale));

        final pageText = await page.loadStructuredText();
        textBlocks.add(_mapPdfTextToOcrBlocks(pageText, page.width, page.height));
      }
    } finally {
      await document.dispose();
    }

    return PdfImportResult(
      imagePaths: [], 
      pageDimensions: pageDimensions,
      textBlocks: textBlocks,
      imageSizes: imageSizes,
    );
  }

  List<OcrTextBlock> _mapPdfTextToOcrBlocks(PdfPageText pdfText, double width, double height) {
    final fragments = pdfText.fragments;
    final linesMap = <double, List<PdfPageTextFragment>>{};
    
    for (final fragment in fragments) {
      final y = (fragment.bounds.top * 10).roundToDouble() / 10;
      linesMap.putIfAbsent(y, () => []).add(fragment);
    }

    final sortedY = linesMap.keys.toList()..sort((a, b) => b.compareTo(a));
    final ocrLines = <OcrTextLine>[];

    for (final y in sortedY) {
      final lineFragments = linesMap[y]!;
      lineFragments.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      
      final List<OcrTextElement> elements = lineFragments.map((f) => OcrTextElement(
        text: f.text,
        left: f.bounds.left * _renderScale,
        top: (height - f.bounds.top) * _renderScale,
        width: f.bounds.width * _renderScale,
        height: f.bounds.height * _renderScale,
      )).toList();

      ocrLines.add(OcrTextLine(
        text: lineFragments.map((f) => f.text).join(' '),
        elements: elements,
      ));
    }

    if (ocrLines.isEmpty) return [];
    
    return [
      OcrTextBlock(
        text: ocrLines.map((l) => l.text).join('\n'),
        left: 0,
        top: 0,
        width: width * _renderScale,
        height: height * _renderScale,
        lines: ocrLines,
      )
    ];
  }
}
