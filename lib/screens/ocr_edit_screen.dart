import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/scan_document.dart';
import '../services/pdf_service.dart';
import '../services/scanner_service.dart';
import '../services/storage_service.dart';

/// Corner handles that appear on a selected bounding box to allow resizing.
enum _ResizeHandle { topLeft, topRight, bottomLeft, bottomRight }

/// Active FAB interaction mode.
///
/// [move]  – any single-finger drag moves the selected element.
/// [scale] – only resize-handle drags are accepted (handles use a larger
///           hit area so they are easier to grab).
enum _FabMode { move, scale }

/// Actions available in the unsaved-changes dialog.
enum _UnsavedChangesAction { save, discard, cancel }

/// Screen for editing the OCR text of a scanned document at the word level.
///
/// Displays each page image inside an [InteractiveViewer] (for pinch-to-zoom
/// and panning). Over the image, every recognised word is highlighted with a
/// semi-transparent overlay whose position matches the original OCR bounding
/// box exactly. Tapping a word overlay opens a dialog to correct its text
/// while keeping its bounding box unchanged.
///
/// Box editing is always active:
///   • Tap on a box (unselected)   → select it (FABs appear).
///   • Tap on a box (selected)     → deselect.
///   • Tap on empty canvas         → deselect.
///   • Drag selected box           → move it.
///   • Drag corner handle          → resize the selected box.
///   • FAB (+, green)              → add a new box at the viewport centre.
///   • FAB (edit, blue)            → edit the selected box's text.
///   • FAB (delete, red)           → delete the selected bounding box.
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
  // Layout cache – updated by LayoutBuilder so _addBoxAtCenter can place new
  // boxes at the viewport centre rather than the PDF centre.
  // ---------------------------------------------------------------------------

  double _currentScale = 1.0;
  double _currentOffsetX = 0.0;
  double _currentOffsetY = 0.0;
  double _currentAvailableWidth = 300.0;
  double _currentAvailableHeight = 500.0;

  // TransformationController tracks the InteractiveViewer's current zoom/pan
  // transform so that _addBoxAtCenter can place new boxes at the visible
  // centre even when the user has zoomed in.
  final TransformationController _transformationController =
      TransformationController();

  // ---------------------------------------------------------------------------
  // Undo / redo history
  // ---------------------------------------------------------------------------

  final List<List<List<OcrTextBlock>>> _undoStack = [];
  final List<List<List<OcrTextBlock>>> _redoStack = [];

  // ---------------------------------------------------------------------------
  // Box-editing state (always active)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // FAB interaction mode
  // ---------------------------------------------------------------------------

  /// Currently active FAB mode (move / scale) or null for default behaviour.
  _FabMode? _activeFabMode;

  /// True when the bounding-box edit mode is active for the selected element.
  ///
  /// Only the OK and Cancel FABs can exit this mode.
  bool _boxEditMode = false;

  /// Snapshot of [_textBlocks] taken when box-edit mode is entered.
  ///
  /// Restored when the user presses Cancel so that all in-session changes are
  /// reverted.
  List<List<OcrTextBlock>>? _editModeSnapshot;

  /// True while a single-finger drag is panning the image (not editing a box).
  bool _isImagePanning = false;

  // Move sub-state: which element is currently being dragged.
  int? _dragPageIdx;
  int? _dragBlockIdx;
  int? _dragLineIdx;
  int? _dragElemIdx;
  Offset? _dragLastPos; // last drag position in Stack (display) coordinates

  // Selection sub-state: which element is currently selected (for FAB delete).
  int? _selectedPageIdx;
  int? _selectedBlockIdx;
  int? _selectedLineIdx;
  int? _selectedElemIdx;

  // Resize sub-state: active corner handle being dragged.
  _ResizeHandle? _activeResizeHandle;

  // The handle that the finger is currently pressing (set on pointer-down,
  // before any drag movement starts; cleared on pointer-up / cancel).
  _ResizeHandle? _pressedResizeHandle;

  // ---------------------------------------------------------------------------
  // Raw-pointer tracking (used by the Listener that replaces GestureDetector)
  // ---------------------------------------------------------------------------

  // Maps each active pointer id to its current local position.
  final Map<int, Offset> _activePointerPositions = {};

  // Position of the first (and only) pointer when it was put down; cleared
  // when the pointer is lifted or when a second pointer joins.
  Offset? _panGestureDownPosition;

  // True once the single active pointer has moved more than kTouchSlop and
  // _handleEditPanStart has been called.
  bool _panGestureActive = false;

  // True when the long-press timer has fired; suppresses the normal tap on
  // the subsequent pointer-up event.
  bool _longPressFired = false;

  // Timer used to detect long-press gestures for debug coordinate display.
  Timer? _longPressTimer;

  // Timer used to detect long-press gestures for overlapping-box selection.
  Timer? _boxSelectionLongPressTimer;

  // ---------------------------------------------------------------------------
  // Debug state
  // ---------------------------------------------------------------------------

  /// Image-pixel coordinates of the last long-press position (null when hidden).
  Offset? _debugLongPressImageCoords;

  /// Display (Stack) coordinates of the last long-press (used to position the
  /// debug label near the tap point).
  Offset? _debugLongPressDisplayPos;

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

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _boxSelectionLongPressTimer?.cancel();
    _transformationController.dispose();
    super.dispose();
  }

  /// Reads the natural (pixel) dimensions of every page image.
  ///
  /// Uses [ui.instantiateImageCodec] so that EXIF rotation is respected on
  /// all platforms – the returned size matches exactly what [Image.file]
  /// displays, preventing coordinate mismatches between the overlays and the
  /// rendered image (vertical offset issue).
  Future<void> _loadImageSizes() async {
    for (var i = 0; i < _document.imagePaths.length; i++) {
      try {
        final bytes = await File(_document.imagePaths[i]).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final w = frame.image.width.toDouble();
        final h = frame.image.height.toDouble();
        frame.image.dispose();
        codec.dispose();
        if (mounted) {
          setState(() => _imageSizes[i] = _ImageSize(w, h));
        }
      } catch (_) {
        // Leave null; overlays will simply be omitted for this page.
      }
    }
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
      _pushUndo();
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
    _pushUndo();
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

      final newElement = OcrTextElement(
        text: text,
        left: left,
        top: top,
        width: width,
        height: height,
      );
      final newLine = OcrTextLine(text: text, elements: [newElement]);
      final newBlock = OcrTextBlock(
        text: text,
        left: left,
        top: top,
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

  /// Adds a new bounding box at the centre of the current viewport and
  /// prompts the user to enter text. Box dimensions are derived from the
  /// measured text so that the overlay fits the word exactly.
  Future<void> _addBoxAtCenter() async {
    if (!mounted) return;

    // Capture the current viewport state BEFORE opening the dialog.
    // Keyboard show/hide during the dialog (triggered by the text field) can
    // change layout metrics and the InteractiveViewer transformation while the
    // dialog is open, which would otherwise mis-place the new box.
    final capturedPage = _currentPage;
    final capturedScale = _currentScale > 0 ? _currentScale : 1.0;
    final capturedOffsetX = _currentOffsetX;
    final capturedOffsetY = _currentOffsetY;
    final capturedViewportCenter =
        Offset(_currentAvailableWidth / 2, _currentAvailableHeight / 2);
    final capturedSceneCenter =
        _transformationController.toScene(capturedViewportCenter);

    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _EditWordDialog(initialText: ''),
    );

    if (text == null || text.isEmpty || !mounted) return;

    // Measure the text at a fixed screen font size (16 logical pixels) so
    // the new box wraps the word tightly regardless of the current zoom level.
    const screenFontSize = 16.0;
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: screenFontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);

    // Convert screen pixels to image coordinate space.
    // The rendering ratio 0.95 mirrors the TextStyle used in _buildWordOverlay
    // (fontSize: height * 0.95), so dividing by it gives the required box height.
    const textRenderRatio = 0.95;
    const horizontalBoxPadding = 8.0; // extra pixels left + right inside the box
    final boxWidth =
        (textPainter.width + horizontalBoxPadding) / capturedScale;
    final boxHeight = textPainter.height / capturedScale / textRenderRatio;

    // Place box at the centre of the visible viewport (not the PDF centre).
    // Use the captured scene centre so that keyboard / layout changes during
    // the dialog do not affect the placement.
    final imgCX =
        (capturedSceneCenter.dx - capturedOffsetX) / capturedScale;
    final imgCY =
        (capturedSceneCenter.dy - capturedOffsetY) / capturedScale;
    final left = imgCX - boxWidth / 2;
    final top = imgCY - boxHeight / 2;

    _pushUndo();
    // Index the new block will occupy after insertion (computed before any
    // mutation so we can select it in the same setState).
    final newBlockIdx = capturedPage < _textBlocks.length
        ? _textBlocks[capturedPage].length
        : 0;

    // Add the block (mirrors _addNewBox logic) and immediately enter edit
    // mode for it.
    final newElement = OcrTextElement(
      text: text,
      left: left,
      top: top,
      width: boxWidth,
      height: boxHeight,
    );
    final newLine = OcrTextLine(text: text, elements: [newElement]);
    final newBlock = OcrTextBlock(
      text: text,
      left: left,
      top: top,
      width: boxWidth,
      height: boxHeight,
      lines: [newLine],
    );
    setState(() {
      _hasChanges = true;
      while (_textBlocks.length <= capturedPage) {
        _textBlocks.add([]);
      }
      _textBlocks[capturedPage] = [..._textBlocks[capturedPage], newBlock];
      // Select the new box.
      _selectedPageIdx = capturedPage;
      _selectedBlockIdx = newBlockIdx;
      _selectedLineIdx = 0;
      _selectedElemIdx = 0;
      // Save snapshot BEFORE edit mode begins so Cancel removes the new box.
      _editModeSnapshot = _deepCopyBlocks(
        _undoStack.last, // top of undo stack = state before the new box
      );
      _boxEditMode = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Box edit mode
  // ---------------------------------------------------------------------------

  /// Activates bounding-box edit mode for the currently selected element.
  ///
  /// A snapshot of [_textBlocks] is saved so [_exitBoxEditModeCancel] can
  /// revert any changes made during the session.
  void _enterBoxEditMode() {
    setState(() {
      _editModeSnapshot = _deepCopyBlocks(_textBlocks);
      _boxEditMode = true;
    });
  }

  /// Exits bounding-box edit mode, keeping all changes.
  void _exitBoxEditModeOk() {
    setState(() {
      _boxEditMode = false;
      _editModeSnapshot = null;
      _activeFabMode = null;
    });
  }

  /// Exits bounding-box edit mode and reverts all changes made since edit
  /// mode was entered (restores the snapshot).
  void _exitBoxEditModeCancel() {
    setState(() {
      if (_editModeSnapshot != null) {
        _textBlocks = _editModeSnapshot!;
        _editModeSnapshot = null;
        _hasChanges = _undoStack.isNotEmpty;
      }
      _boxEditMode = false;
      _activeFabMode = null;
      _selectedPageIdx = null;
      _selectedBlockIdx = null;
      _selectedLineIdx = null;
      _selectedElemIdx = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Box-editing gesture handlers
  // ---------------------------------------------------------------------------

  /// Handles a tap:
  ///   • Tap on an unselected box  → select it (context FABs appear).
  ///   • Tap on the selected box   → deselect (unless box-edit mode is active).
  ///   • Tap on empty canvas       → deselect (unless box-edit mode is active).
  void _handleEditTap(
    Offset pos,
    int pageIdx,
    List<OcrTextBlock> blocks,
    double scale,
    double offsetX,
    double offsetY,
  ) {
    // Clear the long-press debug overlay on any tap.
    if (_debugLongPressImageCoords != null) {
      _debugLongPressImageCoords = null;
      _debugLongPressDisplayPos = null;
    }

    // When box-edit mode is active, all interactions are locked: only the
    // OK / Cancel FABs can change the selection or exit the mode.
    if (_boxEditMode) return;

    for (var bi = 0; bi < blocks.length; bi++) {
      for (var li = 0; li < blocks[bi].lines.length; li++) {
        for (var ei = 0;
            ei < blocks[bi].lines[li].elements.length;
            ei++) {
          final el = blocks[bi].lines[li].elements[ei];
          final elDisplayW = el.width * scale;
          final elDisplayH = el.height * scale;
          final boxRect = Rect.fromCenter(
            center: Offset(
              el.left * scale + offsetX + elDisplayW / 2,
              el.top * scale + offsetY + elDisplayH / 2,
            ),
            width: math.max(elDisplayW, _kMinBoxHitSize),
            height: math.max(elDisplayH, _kMinBoxHitSize),
          );
          if (boxRect.contains(pos)) {
            if (_selectedPageIdx == pageIdx &&
                _selectedBlockIdx == bi &&
                _selectedLineIdx == li &&
                _selectedElemIdx == ei) {
              // Already selected → deselect (use the FAB to edit text).
              setState(() {
                _selectedPageIdx = null;
                _selectedBlockIdx = null;
                _selectedLineIdx = null;
                _selectedElemIdx = null;
              });
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
    // Tapped on empty canvas → deselect only when no FAB mode is active.
    // When a FAB mode is active, only the FAB button itself can deactivate it.
    if (_activeFabMode == null) {
      setState(() {
        _selectedPageIdx = null;
        _selectedBlockIdx = null;
        _selectedLineIdx = null;
        _selectedElemIdx = null;
      });
    }
  }

  /// Handles pan-start in box-editing mode: determines whether to enter
  /// resize mode (started on a corner handle of the selected box), move mode
  /// (started on the already-selected box), select mode (started on a
  /// different unselected box), image-pan mode (started on empty canvas), or
  /// – when a FAB mode is active – the corresponding FAB-mode behaviour.
  void _handleEditPanStart(
    Offset pos,
    int pageIdx,
    List<OcrTextBlock> blocks,
    double scale,
    double offsetX,
    double offsetY,
  ) {
    // 0a. FAB move mode: any drag immediately moves the selected element.
    if (_activeFabMode == _FabMode.move &&
        _selectedPageIdx == pageIdx &&
        _selectedBlockIdx != null &&
        _selectedLineIdx != null &&
        _selectedElemIdx != null) {
      _pushUndo();
      setState(() {
        _dragPageIdx = pageIdx;
        _dragBlockIdx = _selectedBlockIdx;
        _dragLineIdx = _selectedLineIdx;
        _dragElemIdx = _selectedElemIdx;
        _dragLastPos = pos;
      });
      return;
    }

    // 0b. FAB scale mode: only resize-handle drags are accepted (larger hit
    //     area).  Any drag that does not start on a handle is silently ignored.
    if (_activeFabMode == _FabMode.scale &&
        _selectedPageIdx == pageIdx &&
        _selectedBlockIdx != null &&
        _selectedLineIdx != null &&
        _selectedElemIdx != null) {
      final sel = blocks[_selectedBlockIdx!]
          .lines[_selectedLineIdx!]
          .elements[_selectedElemIdx!];
      final selLeft = sel.left * scale + offsetX;
      final selTop = sel.top * scale + offsetY;
      final selWidth = sel.width * scale;
      final selHeight = sel.height * scale;
      final handle = _hitTestResizeHandle(
        pos,
        selLeft,
        selTop,
        selWidth,
        selHeight,
        hitSize: _kHandleHitSizeScaleMode,
        minSpread: _kMinHandleSpread,
      );
      if (handle != null) {
        _pushUndo();
        setState(() {
          _activeResizeHandle = handle;
          _dragLastPos = pos;
          _dragPageIdx = null;
          _dragBlockIdx = null;
          _dragLineIdx = null;
          _dragElemIdx = null;
        });
      }
      return;
    }

    // 1. Check resize handles of the currently selected element first.
    if (_selectedPageIdx == pageIdx &&
        _selectedBlockIdx != null &&
        _selectedLineIdx != null &&
        _selectedElemIdx != null) {
      final sel = blocks[_selectedBlockIdx!]
          .lines[_selectedLineIdx!]
          .elements[_selectedElemIdx!];
      final selLeft = sel.left * scale + offsetX;
      final selTop = sel.top * scale + offsetY;
      final selWidth = sel.width * scale;
      final selHeight = sel.height * scale;
      final handle = _hitTestResizeHandle(pos, selLeft, selTop, selWidth, selHeight);
      if (handle != null) {
        _pushUndo();
        setState(() {
          _activeResizeHandle = handle;
          _dragLastPos = pos;
          _dragPageIdx = null;
          _dragBlockIdx = null;
          _dragLineIdx = null;
          _dragElemIdx = null;
        });
        return;
      }
    }

    // 2. Check if pan starts on a box.
    for (var bi = 0; bi < blocks.length; bi++) {
      for (var li = 0; li < blocks[bi].lines.length; li++) {
        for (var ei = 0;
            ei < blocks[bi].lines[li].elements.length;
            ei++) {
          final el = blocks[bi].lines[li].elements[ei];
          final elDisplayW = el.width * scale;
          final elDisplayH = el.height * scale;
          final boxRect = Rect.fromCenter(
            center: Offset(
              el.left * scale + offsetX + elDisplayW / 2,
              el.top * scale + offsetY + elDisplayH / 2,
            ),
            width: math.max(elDisplayW, _kMinBoxHitSize),
            height: math.max(elDisplayH, _kMinBoxHitSize),
          );
          if (boxRect.contains(pos)) {
            if (_selectedPageIdx == pageIdx &&
                _selectedBlockIdx == bi &&
                _selectedLineIdx == li &&
                _selectedElemIdx == ei) {
              // Already selected → enter move mode.
              _pushUndo();
              setState(() {
                _dragPageIdx = pageIdx;
                _dragBlockIdx = bi;
                _dragLineIdx = li;
                _dragElemIdx = ei;
                _dragLastPos = pos;
              });
            } else if (!_boxEditMode) {
              // Not yet selected, and not locked in edit mode → select it.
              setState(() {
                _selectedPageIdx = pageIdx;
                _selectedBlockIdx = bi;
                _selectedLineIdx = li;
                _selectedElemIdx = ei;
              });
            }
            // When _boxEditMode is true and this is a different box, ignore.
            return;
          }
        }
      }
    }

    // 3. Empty canvas – when a FAB mode is active, or when box-edit mode is
    //    active, do nothing (selection and mode should only be cleared via the
    //    FAB buttons themselves).
    if (_activeFabMode != null || _boxEditMode) return;

    // No FAB mode, no box-edit mode: deselect and start image pan.
    _isImagePanning = true;
    setState(() {
      _selectedPageIdx = null;
      _selectedBlockIdx = null;
      _selectedLineIdx = null;
      _selectedElemIdx = null;
      _dragPageIdx = null;
      _dragBlockIdx = null;
      _dragLineIdx = null;
      _dragElemIdx = null;
      _dragLastPos = null;
    });
  }

  /// Returns the [_ResizeHandle] whose hit-area contains [pos], or null.
  ///
  /// Each corner is represented by a [hitSize]×[hitSize] square centred on the
  /// corner point of the box described by [left], [top], [width], [height] (all
  /// in display / Stack coordinates).  The default [hitSize] is
  /// [_kHandleHitSize]; pass [_kHandleHitSizeScaleMode] for a larger target
  /// when the scale FAB mode is active.
  ///
  /// When [minSpread] > 0 the effective corner positions are spread out so
  /// that the distance between adjacent corners is at least [minSpread].  This
  /// ensures that very small boxes still have reachable, non-overlapping handle
  /// hit areas (used together with [_kHandleHitSizeScaleMode]).
  static const double _kHandleHitSize = 24.0;
  static const double _kHandleHitSizeScaleMode = 48.0;

  /// Minimum spread (display px) applied in scale-FAB mode so handle
  /// hit areas never overlap even for very small boxes.
  static const double _kMinHandleSpread = _kHandleHitSizeScaleMode;

  /// Minimum hit size (scene pixels) used when hit-testing a bounding box so
  /// that very small boxes can still be tapped and dragged reliably.
  static const double _kMinBoxHitSize = 28.0;

  /// Fraction of the overlay height used as the OCR text font size.
  /// 80 % leaves a small top/bottom margin so descenders are not clipped.
  static const double _kOcrTextHeightRatio = 0.80;

  /// Returns the four effective corner positions for resize handles, ensuring
  /// adjacent corners are at least [minSpread] pixels apart.  For large boxes
  /// the actual corners are returned unchanged.
  static Map<_ResizeHandle, Offset> _effectiveHandleCorners(
    double left,
    double top,
    double width,
    double height, {
    double minSpread = 0,
  }) {
    final cx = left + width / 2;
    final cy = top + height / 2;
    final hw = math.max(width, minSpread) / 2;
    final hh = math.max(height, minSpread) / 2;
    return {
      _ResizeHandle.topLeft: Offset(cx - hw, cy - hh),
      _ResizeHandle.topRight: Offset(cx + hw, cy - hh),
      _ResizeHandle.bottomLeft: Offset(cx - hw, cy + hh),
      _ResizeHandle.bottomRight: Offset(cx + hw, cy + hh),
    };
  }

  static _ResizeHandle? _hitTestResizeHandle(
    Offset pos,
    double left,
    double top,
    double width,
    double height, {
    double hitSize = _kHandleHitSize,
    double minSpread = 0,
  }) {
    final h = hitSize / 2;
    final corners = _effectiveHandleCorners(left, top, width, height, minSpread: minSpread);
    for (final entry in corners.entries) {
      final rect = Rect.fromCenter(center: entry.value, width: h * 2, height: h * 2);
      if (rect.contains(pos)) return entry.key;
    }
    return null;
  }

  void _handleEditPanUpdate(Offset pos, double scale) {
    // Image pan mode: translate the viewport via TransformationController.
    if (_isImagePanning) {
      final delta = pos - (_dragLastPos ?? pos);
      _dragLastPos = pos;
      final matrix = _transformationController.value.clone();
      matrix.translate(delta.dx, delta.dy);
      _transformationController.value = matrix;
      return;
    }

    if (_activeResizeHandle != null &&
        _selectedPageIdx != null &&
        _selectedBlockIdx != null &&
        _selectedLineIdx != null &&
        _selectedElemIdx != null) {
      // Resize mode: adjust element dimensions according to the dragged corner.
      final delta = pos - (_dragLastPos ?? pos);
      setState(() {
        _hasChanges = true;
        _dragLastPos = pos;

        final pageIdx = _selectedPageIdx!;
        final blockIdx = _selectedBlockIdx!;
        final lineIdx = _selectedLineIdx!;
        final elemIdx = _selectedElemIdx!;

        final el = _textBlocks[pageIdx][blockIdx].lines[lineIdx].elements[elemIdx];
        final dx = delta.dx / scale;
        final dy = delta.dy / scale;

        double newLeft = el.left;
        double newTop = el.top;
        double newWidth = el.width;
        double newHeight = el.height;

        switch (_activeResizeHandle!) {
          case _ResizeHandle.topLeft:
            newLeft = el.left + dx;
            newTop = el.top + dy;
            newWidth = el.width - dx;
            newHeight = el.height - dy;
          case _ResizeHandle.topRight:
            newTop = el.top + dy;
            newWidth = el.width + dx;
            newHeight = el.height - dy;
          case _ResizeHandle.bottomLeft:
            newLeft = el.left + dx;
            newWidth = el.width - dx;
            newHeight = el.height + dy;
          case _ResizeHandle.bottomRight:
            newWidth = el.width + dx;
            newHeight = el.height + dy;
        }

        // Enforce a minimum size so the box never collapses.
        // Unit: image pixels (same coordinate space as element.left/top/width/height).
        const minSize = 10.0;
        if (newWidth < minSize) {
          if (_activeResizeHandle == _ResizeHandle.topLeft ||
              _activeResizeHandle == _ResizeHandle.bottomLeft) {
            newLeft = el.left + el.width - minSize;
          }
          newWidth = minSize;
        }
        if (newHeight < minSize) {
          if (_activeResizeHandle == _ResizeHandle.topLeft ||
              _activeResizeHandle == _ResizeHandle.topRight) {
            newTop = el.top + el.height - minSize;
          }
          newHeight = minSize;
        }

        final updatedEl = OcrTextElement(
          text: el.text,
          left: newLeft,
          top: newTop,
          width: newWidth,
          height: newHeight,
        );

        final line = _textBlocks[pageIdx][blockIdx].lines[lineIdx];
        final updatedElements =
            List<OcrTextElement>.from(line.elements)..[elemIdx] = updatedEl;
        final updatedLine = line.copyWith(elements: updatedElements);

        final block = _textBlocks[pageIdx][blockIdx];
        final updatedLines =
            List<OcrTextLine>.from(block.lines)..[lineIdx] = updatedLine;

        // Rebuild the block with updated geometry.
        final updatedBlock = OcrTextBlock(
          text: block.text,
          left: newLeft,
          top: newTop,
          width: newWidth,
          height: newHeight,
          lines: updatedLines,
        );

        _textBlocks[pageIdx] =
            List<OcrTextBlock>.from(_textBlocks[pageIdx])..[blockIdx] = updatedBlock;
      });
    } else if (_dragElemIdx != null &&
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
        final newLeft = el.left + delta.dx / scale;
        final newTop = el.top + delta.dy / scale;

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

        // Rebuild block with updated position.
        final updatedBlock = OcrTextBlock(
          text: block.text,
          left: newLeft,
          top: newTop,
          width: block.width,
          height: block.height,
          lines: updatedLines,
        );

        _textBlocks[_dragPageIdx!] =
            List<OcrTextBlock>.from(_textBlocks[_dragPageIdx!])
              ..[_dragBlockIdx!] = updatedBlock;
      });
    }
  }

  void _handleEditPanEnd() {
    if (_isImagePanning) {
      _isImagePanning = false;
      _dragLastPos = null;
      return;
    }
    if (_activeResizeHandle != null) {
      // Finish resize – clear resize state.
      setState(() {
        _activeResizeHandle = null;
        _dragLastPos = null;
      });
    } else if (_dragElemIdx != null) {
      // Finish move – clear drag state.
      setState(() {
        _dragPageIdx = null;
        _dragBlockIdx = null;
        _dragLineIdx = null;
        _dragElemIdx = null;
        _dragLastPos = null;
      });
    }
  }

  /// Clears all transient box-editing state (called on page change).
  void _clearEditState() {
    _dragPageIdx = null;
    _dragBlockIdx = null;
    _dragLineIdx = null;
    _dragElemIdx = null;
    _dragLastPos = null;
    _selectedPageIdx = null;
    _selectedBlockIdx = null;
    _selectedLineIdx = null;
    _selectedElemIdx = null;
    _activeResizeHandle = null;
    _pressedResizeHandle = null;
    _activeFabMode = null;
    _boxEditMode = false;
    _editModeSnapshot = null;
    _isImagePanning = false;
    _activePointerPositions.clear();
    _panGestureDownPosition = null;
    _panGestureActive = false;
    _longPressFired = false;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _boxSelectionLongPressTimer?.cancel();
    _boxSelectionLongPressTimer = null;
    _debugLongPressImageCoords = null;
    _debugLongPressDisplayPos = null;
  }

  // ---------------------------------------------------------------------------
  // Undo / redo
  // ---------------------------------------------------------------------------

  /// Creates a deep copy of [blocks] for snapshot storage.
  static List<List<OcrTextBlock>> _deepCopyBlocks(
      List<List<OcrTextBlock>> blocks) {
    return blocks
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
  }

  /// Saves the current text-blocks state to the undo stack and clears redo.
  void _pushUndo() {
    _undoStack.add(_deepCopyBlocks(_textBlocks));
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _redoStack.add(_deepCopyBlocks(_textBlocks));
      _textBlocks = _undoStack.removeLast();
      // When the undo stack is empty we have reverted all session changes and
      // the current state equals the state at the time the screen was opened,
      // so there are no unsaved changes.
      _hasChanges = _undoStack.isNotEmpty;
      _clearEditState();
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _undoStack.add(_deepCopyBlocks(_textBlocks));
      _textBlocks = _redoStack.removeLast();
      _hasChanges = true;
      _clearEditState();
    });
  }

  // ---------------------------------------------------------------------------
  // Unsaved-changes dialog
  // ---------------------------------------------------------------------------

  Future<_UnsavedChangesAction?> _showUnsavedChangesDialog() {
    return showDialog<_UnsavedChangesAction>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ungespeicherte Änderungen'),
        content: const Text(
          'Es gibt ungespeicherte Änderungen. '
          'Möchten Sie diese speichern oder verwerfen?',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_UnsavedChangesAction.cancel),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_UnsavedChangesAction.discard),
            child: const Text('Verwerfen'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_UnsavedChangesAction.save),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
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
    final hasSelection = _selectedPageIdx != null &&
        _selectedBlockIdx != null &&
        _selectedLineIdx != null &&
        _selectedElemIdx != null;

    return PopScope(
      // Only allow an unintercepted pop when there are no unsaved changes.
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return; // Pop succeeded normally (no changes).
        final action = await _showUnsavedChangesDialog();
        if (!mounted) return;
        if (action == _UnsavedChangesAction.save) {
          await _saveChanges();
        } else if (action == _UnsavedChangesAction.discard) {
          if (mounted) Navigator.of(context).pop();
        }
        // cancel / null: stay on screen.
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit OCR Text'),
          actions: [
            // Undo
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Rückgängig',
              onPressed: _undoStack.isNotEmpty ? _undo : null,
            ),
            // Redo
            IconButton(
              icon: const Icon(Icons.redo),
              tooltip: 'Wiederherstellen',
              onPressed: _redoStack.isNotEmpty ? _redo : null,
            ),
            // Toggle OCR-text overlay
            IconButton(
              icon: Icon(
                Icons.text_fields,
                color: _showOcrText ? Colors.blue : null,
              ),
              tooltip: _showOcrText ? 'OCR-Text ausblenden' : 'OCR-Text anzeigen',
              onPressed: () => setState(() => _showOcrText = !_showOcrText),
            ),
            // Save
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
                tooltip: 'Änderungen speichern',
                onPressed: _saveChanges,
              ),
          ],
        ),
        body: _document.imagePaths.isEmpty
            ? const Center(child: Text('No pages available.'))
            : _buildPageViewer(),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ----------------------------------------------------------------
            // Box selected, NOT in edit mode → single "enter edit mode" FAB.
            // ----------------------------------------------------------------
            if (hasSelection && !_boxEditMode) ...[
              FloatingActionButton.small(
                heroTag: 'fab_enter_edit_mode',
                onPressed: _enterBoxEditMode,
                backgroundColor: Colors.orange,
                tooltip: 'Bearbeitungsmodus aktivieren',
                child: const Icon(Icons.edit_outlined, color: Colors.white),
              ),
              const SizedBox(height: 12),
            ],

            // ----------------------------------------------------------------
            // Box edit mode active → action FABs + OK / Cancel.
            // ----------------------------------------------------------------
            if (hasSelection && _boxEditMode) ...[
              // Move
              FloatingActionButton.small(
                heroTag: 'fab_move',
                onPressed: () {
                  setState(() {
                    _activeFabMode =
                        _activeFabMode == _FabMode.move ? null : _FabMode.move;
                  });
                },
                backgroundColor: _activeFabMode == _FabMode.move
                    ? Colors.orange
                    : Colors.blue.shade700,
                tooltip: _activeFabMode == _FabMode.move
                    ? 'Verschieben aktiv – Box ziehen'
                    : 'Verschieben aktivieren',
                child: const Icon(Icons.open_with, color: Colors.white),
              ),
              const SizedBox(height: 8),
              // Scale
              FloatingActionButton.small(
                heroTag: 'fab_scale',
                onPressed: () {
                  setState(() {
                    _activeFabMode = _activeFabMode == _FabMode.scale
                        ? null
                        : _FabMode.scale;
                  });
                },
                backgroundColor: _activeFabMode == _FabMode.scale
                    ? Colors.orange
                    : Colors.blue.shade700,
                tooltip: _activeFabMode == _FabMode.scale
                    ? 'Skalieren aktiv – Eckpunkte ziehen'
                    : 'Skalieren aktivieren',
                child: const Icon(Icons.crop_free, color: Colors.white),
              ),
              const SizedBox(height: 8),
              // Edit text
              FloatingActionButton.small(
                heroTag: 'fab_edit_text',
                onPressed: () => _editElement(
                  _selectedPageIdx!,
                  _selectedBlockIdx!,
                  _selectedLineIdx!,
                  _selectedElemIdx!,
                ),
                backgroundColor: Colors.blue.shade700,
                tooltip: 'Text editieren',
                child: const Icon(Icons.edit, color: Colors.white),
              ),
              const SizedBox(height: 8),
              // Delete
              FloatingActionButton.small(
                heroTag: 'fab_delete',
                onPressed: () {
                  final pageIdx = _selectedPageIdx!;
                  final blockIdx = _selectedBlockIdx!;
                  final lineIdx = _selectedLineIdx!;
                  final elemIdx = _selectedElemIdx!;
                  // Exit edit mode and deselect before deleting.
                  setState(() {
                    _boxEditMode = false;
                    _editModeSnapshot = null;
                    _activeFabMode = null;
                    _selectedPageIdx = null;
                    _selectedBlockIdx = null;
                    _selectedLineIdx = null;
                    _selectedElemIdx = null;
                  });
                  _deleteElement(pageIdx, blockIdx, lineIdx, elemIdx);
                },
                backgroundColor: Colors.red,
                tooltip: 'Löschen',
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              const SizedBox(height: 8),
              // Cancel
              FloatingActionButton.small(
                heroTag: 'fab_cancel',
                onPressed: _exitBoxEditModeCancel,
                backgroundColor: Colors.red.shade700,
                tooltip: 'Bearbeitung abbrechen',
                child: const Icon(Icons.close, color: Colors.white),
              ),
              const SizedBox(height: 8),
              // OK
              FloatingActionButton.small(
                heroTag: 'fab_ok',
                onPressed: _exitBoxEditModeOk,
                backgroundColor: Colors.green,
                tooltip: 'Änderungen übernehmen',
                child: const Icon(Icons.check, color: Colors.white),
              ),
              const SizedBox(height: 12),
            ],

            // Add FAB – always visible.
            FloatingActionButton(
              heroTag: 'fab_add',
              onPressed: _addBoxAtCenter,
              backgroundColor: Colors.green,
              tooltip: 'Neue Bounding Box hinzufügen',
              child: const Icon(Icons.add, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageViewer() {
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            itemCount: _document.imagePaths.length,
            onPageChanged: (index) => setState(() {
              _currentPage = index;
              _clearEditState();
              // Reset zoom/pan when the user swipes to a new page.
              _transformationController.value = Matrix4.identity();
            }),
            itemBuilder: (_, pageIndex) => _buildPage(pageIndex),
          ),
        ),
        if (_document.imagePaths.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Seite ${_currentPage + 1} von ${_document.imagePaths.length}',
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

    // Pinch-to-zoom is enabled via the InteractiveViewer (scaleEnabled: true).
    // Single-finger gestures (tap, pan) are intercepted by the GestureDetector
    // below and used for box selection/editing, so panEnabled remains false to
    // avoid conflicting with box-drag gestures.
    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 0.5,
      maxScale: double.infinity,
      panEnabled: false,
      scaleEnabled: true,
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

          // Cache layout parameters for _addBoxAtCenter (viewport-centre placement).
          if (pageIndex == _currentPage) {
            _currentScale = scale;
            _currentOffsetX = offsetX;
            _currentOffsetY = offsetY;
            _currentAvailableWidth = availableWidth;
            _currentAvailableHeight = availableHeight;
          }

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

          return Listener(
            // A Listener observes raw pointer events without entering Flutter's
            // gesture arena, so it never competes with InteractiveViewer's
            // ScaleGestureRecognizer. This allows pinch-to-zoom to work while
            // we still intercept single-finger taps and drags for box editing.
            onPointerDown: (event) {
              _activePointerPositions[event.pointer] = event.localPosition;
              if (_activePointerPositions.length > 1) {
                // A second finger has joined – cancel any ongoing box editing
                // and let InteractiveViewer handle the multi-touch zoom.
                if (_panGestureActive) {
                  _handleEditPanEnd();
                  _panGestureActive = false;
                }
                _panGestureDownPosition = null;
                _longPressTimer?.cancel();
                _longPressTimer = null;
                _boxSelectionLongPressTimer?.cancel();
                _boxSelectionLongPressTimer = null;
                _longPressFired = false;
              } else {
                _panGestureDownPosition = event.localPosition;
                _panGestureActive = false;
                _longPressFired = false;

                // Scale mode: detect pressed handle immediately on finger-down
                // so the handle lights up before any drag movement (issue 5).
                if (_activeFabMode == _FabMode.scale &&
                    _selectedPageIdx == pageIndex &&
                    _selectedBlockIdx != null &&
                    _selectedLineIdx != null &&
                    _selectedElemIdx != null &&
                    _selectedBlockIdx! < pageBlocks.length) {
                  final sel = pageBlocks[_selectedBlockIdx!]
                      .lines[_selectedLineIdx!]
                      .elements[_selectedElemIdx!];
                  final pressed = _hitTestResizeHandle(
                    event.localPosition,
                    sel.left * scale + offsetX,
                    sel.top * scale + offsetY,
                    sel.width * scale,
                    sel.height * scale,
                    hitSize: _kHandleHitSizeScaleMode,
                    minSpread: _kMinHandleSpread,
                  );
                  if (pressed != null) {
                    setState(() => _pressedResizeHandle = pressed);
                  }
                }

                // Start box-selection long-press timer (1000 ms): shows a
                // picker when multiple bounding boxes overlap at the tap point.
                _boxSelectionLongPressTimer?.cancel();
                _boxSelectionLongPressTimer = Timer(
                  const Duration(milliseconds: 1000),
                  () {
                    if (!mounted) return;
                    final lp = _panGestureDownPosition;
                    if (lp == null) return;
                    final hits = <_BoxHit>[];
                    for (var bi = 0; bi < pageBlocks.length; bi++) {
                      for (var li = 0;
                          li < pageBlocks[bi].lines.length;
                          li++) {
                        for (var ei = 0;
                            ei < pageBlocks[bi].lines[li].elements.length;
                            ei++) {
                          final el =
                              pageBlocks[bi].lines[li].elements[ei];
                          final elDisplayW = el.width * scale;
                          final elDisplayH = el.height * scale;
                          final boxRect = Rect.fromCenter(
                            center: Offset(
                              el.left * scale +
                                  offsetX +
                                  elDisplayW / 2,
                              el.top * scale +
                                  offsetY +
                                  elDisplayH / 2,
                            ),
                            width: math.max(elDisplayW, _kMinBoxHitSize),
                            height: math.max(elDisplayH, _kMinBoxHitSize),
                          );
                          if (boxRect.contains(lp)) {
                            hits.add(_BoxHit(
                              bi: bi,
                              li: li,
                              ei: ei,
                              element: el,
                            ));
                          }
                        }
                      }
                    }
                    if (hits.length < 2) return;
                    _longPressFired = true;
                    _showBoxSelectionSheet(hits, pageIndex);
                  },
                );

                // Start long-press timer for debug coordinate display (5000 ms).
                _longPressTimer?.cancel();
                _longPressTimer = Timer(
                  const Duration(milliseconds: 5000),
                  () {
                    if (!mounted) return;
                    final lp = _panGestureDownPosition;
                    if (lp == null) return;
                    final imgX = (lp.dx - offsetX) / scale;
                    final imgY = (lp.dy - offsetY) / scale;
                    _longPressFired = true;
                    setState(() {
                      _debugLongPressImageCoords = Offset(imgX, imgY);
                      _debugLongPressDisplayPos = lp;
                    });
                  },
                );
              }
            },
            onPointerMove: (event) {
              _activePointerPositions[event.pointer] = event.localPosition;
              if (_activePointerPositions.length == 1) {
                final downPos = _panGestureDownPosition;
                if (downPos != null) {
                  if (!_panGestureActive &&
                      (event.localPosition - downPos).distance > kTouchSlop) {
                    // Movement threshold exceeded: cancel long-press, start drag.
                    _longPressTimer?.cancel();
                    _longPressTimer = null;
                    _boxSelectionLongPressTimer?.cancel();
                    _boxSelectionLongPressTimer = null;
                    _panGestureActive = true;
                    _handleEditPanStart(
                      downPos,
                      pageIndex,
                      pageBlocks,
                      scale,
                      offsetX,
                      offsetY,
                    );
                    // Normalise _dragLastPos to the current position so the
                    // first _handleEditPanUpdate delta is zero (no jump).
                    _dragLastPos = event.localPosition;
                  }
                  if (_panGestureActive) {
                    _handleEditPanUpdate(event.localPosition, scale);
                  }
                }
              }
            },
            onPointerUp: (event) {
              _longPressTimer?.cancel();
              _longPressTimer = null;
              _boxSelectionLongPressTimer?.cancel();
              _boxSelectionLongPressTimer = null;
              if (_activePointerPositions.length == 1) {
                if (_panGestureActive) {
                  _handleEditPanEnd();
                  _panGestureActive = false;
                } else if (!_longPressFired &&
                    _panGestureDownPosition != null) {
                  // Pointer lifted without significant movement or long-press
                  // → treat as tap.
                  _handleEditTap(
                    event.localPosition,
                    pageIndex,
                    pageBlocks,
                    scale,
                    offsetX,
                    offsetY,
                  );
                }
                _panGestureDownPosition = null;
                _longPressFired = false;
              }
              if (_pressedResizeHandle != null) {
                setState(() => _pressedResizeHandle = null);
              }
              _activePointerPositions.remove(event.pointer);
            },
            onPointerCancel: (event) {
              _longPressTimer?.cancel();
              _longPressTimer = null;
              _boxSelectionLongPressTimer?.cancel();
              _boxSelectionLongPressTimer = null;
              _longPressFired = false;
              _activePointerPositions.remove(event.pointer);
              if (_panGestureActive) {
                _handleEditPanEnd();
                _panGestureActive = false;
              }
              _panGestureDownPosition = null;
              if (_pressedResizeHandle != null) {
                setState(() => _pressedResizeHandle = null);
              }
            },
            child: content,
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
    required double scale,
    required double offsetX,
    required double offsetY,
  }) {
    // Display width/height derived from centering offsets.
    final displayWidth = availableWidth - 2 * offsetX;
    final displayHeight = availableHeight - 2 * offsetY;

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
                  isSelected: _selectedPageIdx == pageIndex &&
                      _selectedBlockIdx == bi &&
                      _selectedLineIdx == li &&
                      _selectedElemIdx == ei,
                ),

          // Resize handles for the selected element – only in scale FAB mode.
          if (_activeFabMode == _FabMode.scale &&
              _selectedPageIdx == pageIndex &&
              _selectedBlockIdx != null &&
              _selectedLineIdx != null &&
              _selectedElemIdx != null &&
              _selectedBlockIdx! < pageBlocks.length)
            ..._buildResizeHandles(
              element: pageBlocks[_selectedBlockIdx!]
                  .lines[_selectedLineIdx!]
                  .elements[_selectedElemIdx!],
              scale: scale,
              offsetX: offsetX,
              offsetY: offsetY,
            ),

          // Debug: selected-box info panel (issue 2).
          if (_selectedPageIdx == pageIndex &&
              _selectedBlockIdx != null &&
              _selectedLineIdx != null &&
              _selectedElemIdx != null &&
              _selectedBlockIdx! < pageBlocks.length)
            _buildSelectedBoxDebugOverlay(
              pageBlocks[_selectedBlockIdx!]
                  .lines[_selectedLineIdx!]
                  .elements[_selectedElemIdx!],
            ),

          // Debug: long-press coordinate label (issue 1).
          if (pageIndex == _currentPage &&
              _debugLongPressImageCoords != null &&
              _debugLongPressDisplayPos != null)
            _buildLongPressDebugOverlay(
              _debugLongPressImageCoords!,
              _debugLongPressDisplayPos!,
              availableWidth,
              availableHeight,
            ),
        ],
      ),
    );
  }

  /// Debug overlay: shows image-pixel coordinates at the long-press point.
  ///
  /// Tapping the label dismisses it.
  Widget _buildLongPressDebugOverlay(
    Offset imageCoords,
    Offset displayPos,
    double availableWidth,
    double availableHeight,
  ) {
    const labelW = 150.0;
    const labelH = 70.0;
    const markerR = 6.0;
    // Clamp label position so it stays inside the canvas.
    final labelLeft =
        (displayPos.dx - labelW / 2).clamp(4.0, availableWidth - labelW - 4);
    final labelTop = displayPos.dy > labelH + markerR + 8
        ? displayPos.dy - labelH - markerR - 8
        : displayPos.dy + markerR + 8;

    return Positioned.fill(
      child: Stack(
        children: [
        // Crosshair marker at the tap point.
        Positioned(
          left: displayPos.dx - markerR,
          top: displayPos.dy - markerR,
          width: markerR * 2,
          height: markerR * 2,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
        // Coordinate label.
        Positioned(
          left: labelLeft,
          top: labelTop,
          width: labelW,
          height: labelH,
          child: GestureDetector(
            onTap: () => setState(() {
              _debugLongPressImageCoords = null;
              _debugLongPressDisplayPos = null;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.78),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.red.withOpacity(0.7)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '📍 Bild-Koordinaten',
                    style: TextStyle(
                      color: Colors.yellow,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'x: ${imageCoords.dx.toStringAsFixed(1)} px\n'
                    'y: ${imageCoords.dy.toStringAsFixed(1)} px',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }

  /// Debug overlay: shows the selected element's size and position in image
  /// pixels as a small panel at the top-left of the Stack.
  Widget _buildSelectedBoxDebugOverlay(OcrTextElement element) {
    return Positioned(
      top: 6,
      left: 6,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.72),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.blue.withOpacity(0.7)),
          ),
          child: Text(
            '📦 x:${element.left.toStringAsFixed(0)} '
            'y:${element.top.toStringAsFixed(0)}\n'
            'w:${element.width.toStringAsFixed(0)} '
            'h:${element.height.toStringAsFixed(0)} px',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      ),
    );
  }

  /// Builds four corner resize-handle widgets for the given [element].
  ///
  /// Each handle is a filled circle rendered at the effective corner of the
  /// selected bounding box (corners are spread out by at least
  /// [_kMinHandleSpread] so they remain reachable even on very small boxes).
  /// The handle that is currently pressed or being dragged is highlighted
  /// with a larger size and a white border (issue 5).
  ///
  /// The page-level [Listener] detects drags that start inside a handle's
  /// hit area (see [_hitTestResizeHandle]).
  static const double _kHandleVisualSize = 14.0;
  static const double _kHandleActiveSizeBoost = 6.0;

  List<Widget> _buildResizeHandles({
    required OcrTextElement element,
    required double scale,
    required double offsetX,
    required double offsetY,
  }) {
    final elLeft = element.left * scale + offsetX;
    final elTop = element.top * scale + offsetY;
    final elWidth = element.width * scale;
    final elHeight = element.height * scale;

    // Use effective corners so handles are always reachable even for tiny boxes.
    final corners = _effectiveHandleCorners(
      elLeft,
      elTop,
      elWidth,
      elHeight,
      minSpread: _kMinHandleSpread,
    );

    return corners.entries.map((entry) {
      final handle = entry.key;
      final c = entry.value;
      final isActive =
          handle == _pressedResizeHandle || handle == _activeResizeHandle;
      final size = isActive
          ? _kHandleVisualSize + _kHandleActiveSizeBoost
          : _kHandleVisualSize;

      return Positioned(
        left: c.dx - size / 2,
        top: c.dy - size / 2,
        width: size,
        height: size,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          decoration: BoxDecoration(
            color: isActive ? Colors.orange : Colors.deepOrange,
            shape: BoxShape.circle,
            border: isActive
                ? Border.all(color: Colors.white, width: 2.5)
                : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isActive ? 0.5 : 0.3),
                blurRadius: isActive ? 4 : 2,
                spreadRadius: 0,
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  /// Builds a single word overlay box.
  ///
  /// Unselected boxes: semi-transparent blue fill, no border.
  /// Selected box: deeper blue fill, no border.
  ///
  /// When OCR text is visible the label is centred both horizontally and
  /// vertically in white so it is legible against the blue background.
  ///
  /// The page-level [Listener] handles all taps and drags –
  /// the overlay itself carries no gesture recogniser.
  Widget _buildWordOverlay({
    required OcrTextElement element,
    required double scale,
    required double offsetX,
    required double offsetY,
    required bool showText,
    required bool isSelected,
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
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blue.withOpacity(0.65)
              : Colors.blue.withOpacity(0.35),
        ),
        alignment: Alignment.center,
        child: showText && element.text.isNotEmpty
            ? Text(
                element.text,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  // 80 % of the container height: leaves a small margin top and
                  // bottom so glyphs with descenders (g, y, p…) are not clipped.
                  fontSize: height * _kOcrTextHeightRatio,
                  height: 1,
                ),
              )
            : null,
      ),
    );
  }

  /// Shows a modal bottom sheet listing all [hits] so the user can pick one.
  ///
  /// Called when a 1000 ms long-press is detected and two or more bounding
  /// boxes overlap at the pressed position.
  void _showBoxSelectionSheet(List<_BoxHit> hits, int pageIdx) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Bounding Box auswählen',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              const Divider(height: 1),
              ...hits.map(
                (hit) => ListTile(
                  leading: const Icon(Icons.crop_square),
                  title: Text(
                    hit.element.text.trim().isEmpty
                        ? '(leer)'
                        : hit.element.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    'x:${hit.element.left.toStringAsFixed(0)} '
                    'y:${hit.element.top.toStringAsFixed(0)} '
                    'w:${hit.element.width.toStringAsFixed(0)} '
                    'h:${hit.element.height.toStringAsFixed(0)} px',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    setState(() {
                      _selectedPageIdx = pageIdx;
                      _selectedBlockIdx = hit.bi;
                      _selectedLineIdx = hit.li;
                      _selectedElemIdx = hit.ei;
                    });
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Lightweight record that identifies a hit bounding box within the page tree.
class _BoxHit {
  final int bi;
  final int li;
  final int ei;
  final OcrTextElement element;

  const _BoxHit({
    required this.bi,
    required this.li,
    required this.ei,
    required this.element,
  });
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
