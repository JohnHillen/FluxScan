import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/scan_document.dart';
import '../services/pdf_service.dart';
import '../services/scanner_service.dart';
import '../services/storage_service.dart';

/// Screen for editing the OCR text of a scanned document at the word level.
///
/// Displays each page image inside an [InteractiveViewer] (for pinch-to-zoom
/// and panning). Over the image, every recognised word is highlighted with a
/// semi-transparent overlay whose position matches the original OCR bounding
/// box exactly. Tapping a word overlay opens a dialog to correct its text
/// while keeping its bounding box unchanged.
///
/// When the user saves, the PDF is regenerated using
/// [PdfService.generateSearchablePdf] so that the exported file continues to
/// use the word-level FittedBox strategy for precise text highlighting.
class OcrEditScreen extends StatefulWidget {
  final ScanDocument document;

  const OcrEditScreen({super.key, required this.document});

  @override
  State<OcrEditScreen> createState() => _OcrEditScreenState();
}

class _OcrEditScreenState extends State<OcrEditScreen> {
  final PdfService _pdfService = PdfService();
  final StorageService _storageService = StorageService();

  late ScanDocument _document;

  /// Mutable, per-page list of text blocks. Edited in place when the user
  /// corrects a word; bounding boxes are never modified.
  late List<List<OcrTextBlock>> _textBlocks;

  /// Cached natural dimensions of each page image, loaded on init.
  late List<_ImageSize?> _imageSizes;

  int _currentPage = 0;
  bool _hasChanges = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _document = widget.document;

    // Deep-copy the text blocks so edits don't mutate the original document.
    _textBlocks = (_document.textBlocks ?? [])
        .map(
          (pageBlocks) => pageBlocks
              .map(
                (block) => OcrTextBlock(
                  text: block.text,
                  left: block.left,
                  top: block.top,
                  width: block.width,
                  height: block.height,
                  lines: block.lines
                      .map(
                        (line) => OcrTextLine(
                          text: line.text,
                          elements: line.elements
                              .map(
                                (el) => OcrTextElement(
                                  text: el.text,
                                  left: el.left,
                                  top: el.top,
                                  width: el.width,
                                  height: el.height,
                                ),
                              )
                              .toList(),
                        ),
                      )
                      .toList(),
                ),
              )
              .toList(),
        )
        .toList();

    _imageSizes = List.filled(_document.imagePaths.length, null);
    _loadImageSizes();
  }

  /// Reads the natural (pixel) dimensions of every page image.
  Future<void> _loadImageSizes() async {
    for (var i = 0; i < _document.imagePaths.length; i++) {
      try {
        final bytes = await File(_document.imagePaths[i]).readAsBytes();
        final size = _decodeSizeFromBytes(bytes);
        if (mounted) {
          setState(() => _imageSizes[i] = size);
        }
      } catch (_) {
        // Leave null; overlays will simply be omitted for this page.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Dimension helpers (mirror logic from PdfService._decodeDimensions)
  // ---------------------------------------------------------------------------

  static _ImageSize _decodeSizeFromBytes(List<int> bytes) {
    // PNG
    if (bytes.length > 24 && bytes[0] == 0x89 && bytes[1] == 0x50) {
      final w = (bytes[16] << 24) |
          (bytes[17] << 16) |
          (bytes[18] << 8) |
          bytes[19];
      final h = (bytes[20] << 24) |
          (bytes[21] << 16) |
          (bytes[22] << 8) |
          bytes[23];
      return _ImageSize(w.toDouble(), h.toDouble());
    }
    // JPEG
    if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return _readJpegSize(bytes);
    }
    // Fallback (A4 @ 300 dpi)
    return const _ImageSize(2480, 3508);
  }

  static _ImageSize _readJpegSize(List<int> bytes) {
    var offset = 2;
    while (offset < bytes.length - 1) {
      if (bytes[offset] != 0xFF) break;
      final marker = bytes[offset + 1];
      if (marker >= 0xC0 && marker <= 0xC2) {
        if (offset + 9 < bytes.length) {
          final h = (bytes[offset + 5] << 8) | bytes[offset + 6];
          final w = (bytes[offset + 7] << 8) | bytes[offset + 8];
          return _ImageSize(w.toDouble(), h.toDouble());
        }
      }
      if (offset + 3 < bytes.length) {
        final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
        offset += 2 + length;
      } else {
        break;
      }
    }
    return const _ImageSize(2480, 3508);
  }

  // ---------------------------------------------------------------------------
  // Editing logic
  // ---------------------------------------------------------------------------

  /// Opens a [showDialog] for the word at [blockIdx]/[lineIdx]/[elemIdx] on
  /// [pageIdx] and, if the user saves, updates its text in [_textBlocks].
  Future<void> _editElement(
    int pageIdx,
    int blockIdx,
    int lineIdx,
    int elemIdx,
  ) async {
    final element =
        _textBlocks[pageIdx][blockIdx].lines[lineIdx].elements[elemIdx];
    final controller = TextEditingController(text: element.text);

    try {
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Edit Word'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      if (result != null && result != element.text) {
        setState(() {
          _hasChanges = true;

          // Rebuild the element (text only; bounding box unchanged).
          final updatedElement = element.copyWith(text: result);

          final line = _textBlocks[pageIdx][blockIdx].lines[lineIdx];
          final updatedElements = List<OcrTextElement>.from(line.elements)
            ..[elemIdx] = updatedElement;
          final updatedLine = line.copyWith(
            text: updatedElements.map((e) => e.text).join(' '),
            elements: updatedElements,
          );

          final block = _textBlocks[pageIdx][blockIdx];
          final updatedLines = List<OcrTextLine>.from(block.lines)
            ..[lineIdx] = updatedLine;
          final updatedBlock = block.copyWith(
            text: updatedLines.map((l) => l.text).join('\n'),
            lines: updatedLines,
          );

          _textBlocks[pageIdx] = List<OcrTextBlock>.from(_textBlocks[pageIdx])
            ..[blockIdx] = updatedBlock;
        });
      }
    } finally {
      controller.dispose();
    }
  }

  /// Persists the edits: regenerates the PDF with updated word text and
  /// saves the document, then pops the screen returning the updated document.
  Future<void> _saveChanges() async {
    if (!_hasChanges) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    setState(() => _isSaving = true);

    try {
      const pageBreakDelimiter = '\n\n--- Page Break ---\n\n';
      final updatedOcrText = _textBlocks
          .map((blocks) => blocks.map((b) => b.text).join('\n'))
          .join(pageBreakDelimiter);

      // Regenerate with the mutated OcrTextElement list so word-level
      // bounding boxes (FittedBox strategy) are retained in the PDF.
      final oldPdfPath = _document.pdfPath;
      final newPdfPath = await _pdfService.generateSearchablePdf(
        imagePaths: _document.imagePaths,
        textBlocks: _textBlocks,
        title: _document.title,
      );

      // Clean up the old PDF file (non-fatal on failure).
      if (oldPdfPath != null) {
        try {
          final oldPdf = File(oldPdfPath);
          if (await oldPdf.exists()) await oldPdf.delete();
        } catch (e) {
          debugPrint('Failed to delete old PDF at $oldPdfPath: $e');
        }
      }

      final updated = _document.copyWith(
        ocrText: updatedOcrText,
        textBlocks: _textBlocks,
        pdfPath: newPdfPath,
        updatedAt: DateTime.now(),
      );
      await _storageService.saveDocument(updated);

      if (mounted) {
        Navigator.of(context).pop(updated);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit OCR Text'),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save changes',
              onPressed: _saveChanges,
            ),
        ],
      ),
      body: _document.imagePaths.isEmpty
          ? const Center(child: Text('No pages available.'))
          : _buildPageViewer(),
    );
  }

  Widget _buildPageViewer() {
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            itemCount: _document.imagePaths.length,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (_, pageIndex) => _buildPage(pageIndex),
          ),
        ),
        if (_document.imagePaths.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Page ${_currentPage + 1} of ${_document.imagePaths.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _buildPage(int pageIndex) {
    final imagePath = _document.imagePaths[pageIndex];
    final pageBlocks =
        pageIndex < _textBlocks.length ? _textBlocks[pageIndex] : <OcrTextBlock>[];
    final imageSize = pageIndex < _imageSizes.length ? _imageSizes[pageIndex] : null;

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return _buildImageWithOverlays(
            imagePath: imagePath,
            pageBlocks: pageBlocks,
            pageIndex: pageIndex,
            availableWidth: constraints.maxWidth,
            availableHeight: constraints.maxHeight,
            imageSize: imageSize,
          );
        },
      ),
    );
  }

  Widget _buildImageWithOverlays({
    required String imagePath,
    required List<OcrTextBlock> pageBlocks,
    required int pageIndex,
    required double availableWidth,
    required double availableHeight,
    required _ImageSize? imageSize,
  }) {
    // Overlay coordinates require image dimensions. Until loaded, show image
    // without overlays so the user can at least see the page immediately.
    if (imageSize == null) {
      return Center(
        child: Image.file(
          File(imagePath),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Center(child: Icon(Icons.broken_image, size: 64)),
        ),
      );
    }

    // Compute BoxFit.contain scale and centering offsets, mirroring
    // PdfService.computePageMapping so overlays align with the PDF positions.
    final scale = math.min(
      availableWidth / imageSize.width,
      availableHeight / imageSize.height,
    );
    final displayWidth = imageSize.width * scale;
    final displayHeight = imageSize.height * scale;
    final offsetX = (availableWidth - displayWidth) / 2;
    final offsetY = (availableHeight - displayHeight) / 2;

    return SizedBox(
      width: availableWidth,
      height: availableHeight,
      child: Stack(
        children: [
          // Background: document image positioned at the contain-fit location.
          Positioned(
            left: offsetX,
            top: offsetY,
            width: displayWidth,
            height: displayHeight,
            child: Image.file(
              File(imagePath),
              fit: BoxFit.fill,
              errorBuilder: (_, __, ___) =>
                  const Center(child: Icon(Icons.broken_image, size: 64)),
            ),
          ),

          // Word overlays: one tappable semi-transparent box per element.
          for (var bi = 0; bi < pageBlocks.length; bi++)
            for (var li = 0; li < pageBlocks[bi].lines.length; li++)
              for (var ei = 0;
                  ei < pageBlocks[bi].lines[li].elements.length;
                  ei++)
                _buildWordOverlay(
                  element: pageBlocks[bi].lines[li].elements[ei],
                  scale: scale,
                  offsetX: offsetX,
                  offsetY: offsetY,
                  onTap: () => _editElement(pageIndex, bi, li, ei),
                ),
        ],
      ),
    );
  }

  /// Builds a single semi-transparent word overlay box.
  Widget _buildWordOverlay({
    required OcrTextElement element,
    required double scale,
    required double offsetX,
    required double offsetY,
    required VoidCallback onTap,
  }) {
    final left = element.left * scale + offsetX;
    final top = element.top * scale + offsetY;
    final width = element.width * scale;
    final height = element.height * scale;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.15),
            border: Border.all(
              color: Colors.blue.withOpacity(0.45),
            ),
          ),
        ),
      ),
    );
  }
}

/// Natural (pixel) dimensions of an image.
class _ImageSize {
  final double width;
  final double height;
  const _ImageSize(this.width, this.height);
}
