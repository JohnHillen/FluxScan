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
/// In **box-editing mode** (toggled via the AppBar) the [InteractiveViewer]
/// pan/zoom is suspended and a dedicated [GestureDetector] takes over:
///   • Tap on a box (unselected) → select it (a red delete FAB appears).
///   • Tap on a box (selected)   → edit its text.
///   • Tap on empty canvas       → deselect.
///   • Drag an existing overlay  → move it.
///   • Drag on empty canvas      → draw a new bounding box (text is
///                                  prompted on release).
///   • FAB (delete)              → delete the selected bounding box.
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

  static const _pageBreakDelimiter = '\n\n--- Page Break ---\n\n';

  /// A4 at 300 DPI — used as the fallback when image dimensions cannot be
  /// determined from the file header.
  static const _fallbackImageSize = _ImageSize(2480, 3508);

  late ScanDocument _document;

  /// Mutable, per-page list of text blocks.
  late List<List<OcrTextBlock>> _textBlocks;

  /// Cached natural dimensions of each page image, loaded on init.
  late List<_ImageSize?> _imageSizes;

  int _currentPage = 0;
  bool _hasChanges = false;
  bool _isSaving = false;
  bool _showOcrText = false;

  // ---------------------------------------------------------------------------
  // Box-editing mode state
  // ---------------------------------------------------------------------------

  /// Whether box-editing mode is active. In this mode InteractiveViewer
  /// pan/zoom is disabled and the dedicated edit gesture handler is active.
  bool _isEditingBoxes = false;

  // Move sub-state: which element is currently being dragged.
  int? _dragPageIdx;
  int? _dragBlockIdx;
  int? _dragLineIdx;
  int? _dragElemIdx;
  Offset? _dragLastPos; // last drag position in Stack (display) coordinates

  // Draw sub-state: drawing a new bounding box.
  Offset? _drawStart;   // start position in Stack coordinates
  Offset? _drawCurrent; // current drag position in Stack coordinates

  // Selection sub-state: which element is currently selected (for FAB delete).
  int? _selectedPageIdx;
  int? _selectedBlockIdx;
  int? _selectedLineIdx;
  int? _selectedElemIdx;

  // ---------------------------------------------------------------------------
  // Init / lifecycle
  // ---------------------------------------------------------------------------

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
    return _fallbackImageSize;
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
    return _fallbackImageSize;
  }

  // ---------------------------------------------------------------------------
  // Text-editing logic
  // ---------------------------------------------------------------------------

  /// Opens a dialog for the word at [blockIdx]/[lineIdx]/[elemIdx] on
  /// [pageIdx] and, if the user saves, updates its text in [_textBlocks].
  Future<void> _editElement(
    int pageIdx,
    int blockIdx,
    int lineIdx,
    int elemIdx,
  ) async {
    final element =
        _textBlocks[pageIdx][blockIdx].lines[lineIdx].elements[elemIdx];

    if (!mounted) return;

    final result = await showDialog<String>(
      context: context,
      builder: (_) => _EditWordDialog(initialText: element.text),
    );

    if (!mounted) return;

    if (result != null && result != element.text) {
      setState(() {
        _hasChanges = true;

        final updatedElement = OcrTextElement(
          text: result,
          left: element.left,
          top: element.top,
          width: element.width,
          height: element.height,
        );

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
  }

  // ---------------------------------------------------------------------------
  // Box-editing logic
  // ---------------------------------------------------------------------------

  /// Deletes the element at [blockIdx]/[lineIdx]/[elemIdx] on [pageIdx].
  /// Cascades: removes the enclosing line if it becomes empty, and the
  /// enclosing block if the line removal leaves it empty.
  void _deleteElement(
    int pageIdx,
    int blockIdx,
    int lineIdx,
    int elemIdx,
  ) {
    setState(() {
      _hasChanges = true;

      final page = List<OcrTextBlock>.from(_textBlocks[pageIdx]);
      final block = page[blockIdx];
      final line = block.lines[lineIdx];

      final updatedElements =
          List<OcrTextElement>.from(line.elements)..removeAt(elemIdx);

      if (updatedElements.isEmpty) {
        // Line is now empty – remove it.
        final updatedLines =
            List<OcrTextLine>.from(block.lines)..removeAt(lineIdx);
        if (updatedLines.isEmpty) {
          // Block is now empty – remove it.
          page.removeAt(blockIdx);
        } else {
          page[blockIdx] = block.copyWith(
            text: updatedLines.map((l) => l.text).join('\n'),
            lines: updatedLines,
          );
        }
      } else {
        final updatedLine = line.copyWith(
          text: updatedElements.map((e) => e.text).join(' '),
          elements: updatedElements,
        );
        final updatedLines = List<OcrTextLine>.from(block.lines)
          ..[lineIdx] = updatedLine;
        page[blockIdx] = block.copyWith(
          text: updatedLines.map((l) => l.text).join('\n'),
          lines: updatedLines,
        );
      }

      _textBlocks[pageIdx] = page;
    });
  }

  /// Adds a new single-element block at the given image coordinates.
  void _addNewBox(
    int pageIdx,
    double left,
    double top,
    double width,
    double height,
    String text,
  ) {
    setState(() {
      _hasChanges = true;

      final imgSize = pageIdx < _imageSizes.length
          ? (_imageSizes[pageIdx] ?? _fallbackImageSize)
          : _fallbackImageSize;
      final clampedLeft =
          left.clamp(0.0, math.max(0.0, imgSize.width - width)).toDouble();
      final clampedTop =
          top.clamp(0.0, math.max(0.0, imgSize.height - height)).toDouble();

      final newElement = OcrTextElement(
        text: text,
        left: clampedLeft,
        top: clampedTop,
        width: width,
        height: height,
      );
      final newLine = OcrTextLine(text: text, elements: [newElement]);
      final newBlock = OcrTextBlock(
        text: text,
        left: clampedLeft,
        top: clampedTop,
        width: width,
        height: height,
        lines: [newLine],
      );

      while (_textBlocks.length <= pageIdx) {
        _textBlocks.add([]);
      }
      _textBlocks[pageIdx] = [..._textBlocks[pageIdx], newBlock];
    });
  }

  // ---------------------------------------------------------------------------
  // Box-editing gesture handlers
  // ---------------------------------------------------------------------------

  /// Handles a tap in box-editing mode:
  ///   • Tap on an unselected box  → select it (FAB appears).
  ///   • Tap on the selected box   → edit its text.
  ///   • Tap on empty canvas       → deselect.
  void _handleEditTap(
    Offset pos,
    int pageIdx,
    List<OcrTextBlock> blocks,
    double scale,
    double offsetX,
    double offsetY,
  ) {
    for (var bi = 0; bi < blocks.length; bi++) {
      for (var li = 0; li < blocks[bi].lines.length; li++) {
        for (var ei = 0;
            ei < blocks[bi].lines[li].elements.length;
            ei++) {
          final el = blocks[bi].lines[li].elements[ei];
          final boxRect = Rect.fromLTWH(
            el.left * scale + offsetX,
            el.top * scale + offsetY,
            el.width * scale,
            el.height * scale,
          );
          if (boxRect.contains(pos)) {
            if (_selectedPageIdx == pageIdx &&
                _selectedBlockIdx == bi &&
                _selectedLineIdx == li &&
                _selectedElemIdx == ei) {
              // Already selected → edit text.
              _editElement(pageIdx, bi, li, ei);
            } else {
              // Select it.
              setState(() {
                _selectedPageIdx = pageIdx;
                _selectedBlockIdx = bi;
                _selectedLineIdx = li;
                _selectedElemIdx = ei;
              });
            }
            return;
          }
        }
      }
    }
    // Tapped on empty canvas → deselect.
    setState(() {
      _selectedPageIdx = null;
      _selectedBlockIdx = null;
      _selectedLineIdx = null;
      _selectedElemIdx = null;
    });
  }

  /// Handles pan-start in box-editing mode: determines whether to enter
  /// move mode (started on a box) or draw mode (started on empty canvas).
  void _handleEditPanStart(
    Offset pos,
    int pageIdx,
    List<OcrTextBlock> blocks,
    double scale,
    double offsetX,
    double offsetY,
  ) {
    // Check if pan starts on a box → move mode.
    for (var bi = 0; bi < blocks.length; bi++) {
      for (var li = 0; li < blocks[bi].lines.length; li++) {
        for (var ei = 0;
            ei < blocks[bi].lines[li].elements.length;
            ei++) {
          final el = blocks[bi].lines[li].elements[ei];
          final boxRect = Rect.fromLTWH(
            el.left * scale + offsetX,
            el.top * scale + offsetY,
            el.width * scale,
            el.height * scale,
          );
          if (boxRect.contains(pos)) {
            setState(() {
              _dragPageIdx = pageIdx;
              _dragBlockIdx = bi;
              _dragLineIdx = li;
              _dragElemIdx = ei;
              _dragLastPos = pos;
              _drawStart = null;
              _drawCurrent = null;
            });
            return;
          }
        }
      }
    }

    // Empty canvas → draw mode.
    setState(() {
      _drawStart = pos;
      _drawCurrent = pos;
      _dragPageIdx = null;
      _dragBlockIdx = null;
      _dragLineIdx = null;
      _dragElemIdx = null;
      _dragLastPos = null;
    });
  }

  void _handleEditPanUpdate(Offset pos, double scale) {
    if (_dragElemIdx != null &&
        _dragPageIdx != null &&
        _dragBlockIdx != null &&
        _dragLineIdx != null) {
      // Move mode: translate the element by the drag delta.
      final delta = pos - (_dragLastPos ?? pos);
      setState(() {
        _hasChanges = true;
        _dragLastPos = pos;

        final el = _textBlocks[_dragPageIdx!][_dragBlockIdx!]
            .lines[_dragLineIdx!]
            .elements[_dragElemIdx!];
        final imgSize = _imageSizes[_dragPageIdx!] ?? _fallbackImageSize;
        final newLeft = (el.left + delta.dx / scale)
            .clamp(0.0, math.max(0.0, imgSize.width - el.width)).toDouble();
        final newTop = (el.top + delta.dy / scale)
            .clamp(0.0, math.max(0.0, imgSize.height - el.height)).toDouble();

        final updatedEl = OcrTextElement(
          text: el.text,
          left: newLeft,
          top: newTop,
          width: el.width,
          height: el.height,
        );

        final line = _textBlocks[_dragPageIdx!][_dragBlockIdx!]
            .lines[_dragLineIdx!];
        final updatedElements =
            List<OcrTextElement>.from(line.elements)..[_dragElemIdx!] =
                updatedEl;
        final updatedLine = line.copyWith(elements: updatedElements);

        final block = _textBlocks[_dragPageIdx!][_dragBlockIdx!];
        final updatedLines =
            List<OcrTextLine>.from(block.lines)..[_dragLineIdx!] =
                updatedLine;
        final updatedBlock = block.copyWith(lines: updatedLines);

        _textBlocks[_dragPageIdx!] =
            List<OcrTextBlock>.from(_textBlocks[_dragPageIdx!])
              ..[_dragBlockIdx!] = updatedBlock;
      });
    } else if (_drawStart != null) {
      // Draw mode: update the preview rect.
      setState(() => _drawCurrent = pos);
    }
  }

  Future<void> _handleEditPanEnd(
    int pageIdx,
    double scale,
    double offsetX,
    double offsetY,
  ) async {
    if (_dragElemIdx != null) {
      // Finish move – clear drag state.
      setState(() {
        _dragPageIdx = null;
        _dragBlockIdx = null;
        _dragLineIdx = null;
        _dragElemIdx = null;
        _dragLastPos = null;
      });
    } else if (_drawStart != null && _drawCurrent != null) {
      // Finish drawing – create new box if large enough.
      final drawRect = Rect.fromPoints(_drawStart!, _drawCurrent!);
      setState(() {
        _drawStart = null;
        _drawCurrent = null;
      });

      if (drawRect.width > 10 && drawRect.height > 10) {
        final imgLeft = (drawRect.left - offsetX) / scale;
        final imgTop = (drawRect.top - offsetY) / scale;
        final imgWidth = drawRect.width / scale;
        final imgHeight = drawRect.height / scale;

        if (!mounted) return;
        final text = await showDialog<String>(
          context: context,
          builder: (_) => const _EditWordDialog(initialText: ''),
        );

        if (text != null && text.isNotEmpty && mounted) {
          _addNewBox(pageIdx, imgLeft, imgTop, imgWidth, imgHeight, text);
        }
      }
    }
  }

  /// Clears all transient box-editing state (called on mode toggle and on
  /// page change).
  void _clearEditState() {
    _dragPageIdx = null;
    _dragBlockIdx = null;
    _dragLineIdx = null;
    _dragElemIdx = null;
    _dragLastPos = null;
    _drawStart = null;
    _drawCurrent = null;
    _selectedPageIdx = null;
    _selectedBlockIdx = null;
    _selectedLineIdx = null;
    _selectedElemIdx = null;
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  /// Persists the edits: regenerates the PDF with updated word text and
  /// saves the document, then pops the screen returning the updated document.
  Future<void> _saveChanges() async {
    if (!_hasChanges) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updatedOcrText = _textBlocks
          .map((blocks) => blocks.map((b) => b.text).join('\n'))
          .join(_pageBreakDelimiter);

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
          IconButton(
            icon: Icon(
              Icons.text_fields,
              color: _showOcrText ? Colors.blue : null,
            ),
            tooltip: _showOcrText ? 'Hide OCR text' : 'Show OCR text',
            onPressed: () => setState(() => _showOcrText = !_showOcrText),
          ),
          IconButton(
            icon: Icon(
              Icons.format_shapes,
              color: _isEditingBoxes ? Colors.orange : null,
            ),
            tooltip:
                _isEditingBoxes ? 'Stop editing boxes' : 'Edit boxes',
            onPressed: () => setState(() {
              _isEditingBoxes = !_isEditingBoxes;
              _clearEditState();
            }),
          ),
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
      floatingActionButton: _isEditingBoxes &&
              _selectedPageIdx != null &&
              _selectedBlockIdx != null &&
              _selectedLineIdx != null &&
              _selectedElemIdx != null
          ? FloatingActionButton(
              onPressed: () {
                // Capture indices before clearing selection so they remain
                // valid when passed to _deleteElement (array positions can
                // shift after the deletion).
                final pageIdx = _selectedPageIdx!;
                final blockIdx = _selectedBlockIdx!;
                final lineIdx = _selectedLineIdx!;
                final elemIdx = _selectedElemIdx!;
                setState(() {
                  _selectedPageIdx = null;
                  _selectedBlockIdx = null;
                  _selectedLineIdx = null;
                  _selectedElemIdx = null;
                });
                _deleteElement(pageIdx, blockIdx, lineIdx, elemIdx);
              },
              backgroundColor: Colors.red,
              tooltip: 'Delete selected box',
              child: const Icon(Icons.delete, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildPageViewer() {
    return Column(
      children: [
        // Contextual hint bar shown only in box-editing mode.
        if (_isEditingBoxes)
          ColoredBox(
            color: Colors.orange.shade50,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: const [
                  Icon(Icons.info_outline, size: 14, color: Colors.orange),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Tap = select  •  Tap again = edit  •  '
                      'Drag = move  •  Drag empty area = new box',
                      style: TextStyle(fontSize: 11, color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: PageView.builder(
            itemCount: _document.imagePaths.length,
            onPageChanged: (index) => setState(() {
              _currentPage = index;
              _clearEditState();
            }),
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
    final pageBlocks = pageIndex < _textBlocks.length
        ? _textBlocks[pageIndex]
        : <OcrTextBlock>[];
    final imageSize =
        pageIndex < _imageSizes.length ? _imageSizes[pageIndex] : null;

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 10.0,
      panEnabled: !_isEditingBoxes,
      scaleEnabled: !_isEditingBoxes,
      child: LayoutBuilder(
        builder: (context, constraints) {
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

          final availableWidth = constraints.maxWidth;
          final availableHeight = constraints.maxHeight;
          final scale = math.min(
            availableWidth / imageSize.width,
            availableHeight / imageSize.height,
          );
          final displayWidth = imageSize.width * scale;
          final displayHeight = imageSize.height * scale;
          final offsetX = (availableWidth - displayWidth) / 2;
          final offsetY = (availableHeight - displayHeight) / 2;

          final content = _buildImageWithOverlays(
            imagePath: imagePath,
            pageBlocks: pageBlocks,
            pageIndex: pageIndex,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY,
          );

          if (_isEditingBoxes) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _handleEditTap(
                d.localPosition,
                pageIndex,
                pageBlocks,
                scale,
                offsetX,
                offsetY,
              ),
              onPanStart: (d) => _handleEditPanStart(
                d.localPosition,
                pageIndex,
                pageBlocks,
                scale,
                offsetX,
                offsetY,
              ),
              onPanUpdate: (d) =>
                  _handleEditPanUpdate(d.localPosition, scale),
              onPanEnd: (_) =>
                  _handleEditPanEnd(pageIndex, scale, offsetX, offsetY),
              child: content,
            );
          }

          return content;
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
    required double scale,
    required double offsetX,
    required double offsetY,
  }) {
    // Display width/height derived from centering offsets.
    final displayWidth = availableWidth - 2 * offsetX;
    final displayHeight = availableHeight - 2 * offsetY;

    // Draw-preview rect (in Stack coordinates), if active.
    Rect? drawRect;
    if (_isEditingBoxes && _drawStart != null && _drawCurrent != null) {
      drawRect = Rect.fromPoints(_drawStart!, _drawCurrent!);
    }

    return SizedBox(
      width: availableWidth,
      height: availableHeight,
      child: Stack(
        children: [
          // Background: document image.
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

          // Word overlays.
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
                  showText: _showOcrText,
                  isEditMode: _isEditingBoxes,
                  isSelected: _isEditingBoxes &&
                      _selectedPageIdx == pageIndex &&
                      _selectedBlockIdx == bi &&
                      _selectedLineIdx == li &&
                      _selectedElemIdx == ei,
                  onTap: _isEditingBoxes
                      ? null
                      : () => _editElement(pageIndex, bi, li, ei),
                ),

          // Draw-preview rectangle (shown while dragging on empty canvas).
          if (drawRect != null)
            Positioned(
              left: drawRect.left,
              top: drawRect.top,
              width: drawRect.width,
              height: drawRect.height,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  border: Border.all(color: Colors.green, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Builds a single word overlay box.
  ///
  /// **View mode** (`isEditMode == false`): semi-transparent blue fill with
  /// border; tapping opens the text-edit dialog.
  ///
  /// **Edit mode** (`isEditMode == true`): orange border. When [isSelected]
  /// is true the box is highlighted with a deeper orange border and fill to
  /// indicate that it is the active selection (the red delete FAB is shown
  /// in this state). Tapping a box once selects it; tapping it again edits
  /// its text. The page-level [GestureDetector] (set up in [_buildPage])
  /// handles all taps and drags – the overlay itself carries no gesture
  /// recogniser in edit mode.
  Widget _buildWordOverlay({
    required OcrTextElement element,
    required double scale,
    required double offsetX,
    required double offsetY,
    required bool showText,
    required bool isEditMode,
    required bool isSelected,
    required VoidCallback? onTap,
  }) {
    final left = element.left * scale + offsetX;
    final top = element.top * scale + offsetY;
    final width = element.width * scale;
    final height = element.height * scale;

    if (isEditMode) {
      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.orange.withOpacity(0.35)
                : Colors.orange.withOpacity(0.15),
            border: Border.all(
              color: isSelected ? Colors.deepOrange : Colors.orange,
              width: isSelected ? 2.5 : 1.5,
            ),
          ),
          child: showText && element.text.isNotEmpty
              ? FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  child: Text(
                    element.text,
                    style: const TextStyle(
                      color: Colors.black,
                      height: 1,
                    ),
                  ),
                )
              : null,
        ),
      );
    }

    // View mode.
    final decoration = showText
        ? const BoxDecoration(
            color: Colors.blue,
            border: Border.fromBorderSide(BorderSide(color: Colors.blue)),
          )
        : BoxDecoration(
            color: Colors.blue.withOpacity(0.15),
            border: Border.all(
              color: Colors.blue.withOpacity(0.45),
            ),
          );

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: decoration,
          child: showText && element.text.isNotEmpty
              ? FittedBox(
                  // BoxFit.contain scales text UP as well as down so the
                  // rendered text fills the bounding box to ~95 % of its width.
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  child: Text(
                    element.text,
                    style: const TextStyle(
                      color: Colors.black,
                      height: 1,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// Dialog for correcting a single OCR word.
///
/// Owns the [TextEditingController] so that it is disposed via [State.dispose]
/// after the dialog widget is fully removed from the tree — preventing the
/// `_dependents.isEmpty` assertion that can fire when the controller is
/// disposed while the closing animation is still in progress.
class _EditWordDialog extends StatefulWidget {
  final String initialText;

  const _EditWordDialog({required this.initialText});

  @override
  State<_EditWordDialog> createState() => _EditWordDialogState();
}

class _EditWordDialogState extends State<_EditWordDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Word'),
      content: TextField(
        controller: _controller,
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
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Natural (pixel) dimensions of an image.
class _ImageSize {
  final double width;
  final double height;
  const _ImageSize(this.width, this.height);
}
