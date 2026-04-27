import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:vector_math/vector_math_64.dart' as v64;
import 'package:pdfrx/pdfrx.dart';

import '../../../models/scan_document.dart';
import '../../../services/pdf_service.dart';
import '../../../services/scanner_service.dart';
import '../../../services/storage_service.dart';
import 'ocr_editor_state.dart';

// -----------------------------------------------------------------------------
// Providers
// -----------------------------------------------------------------------------

final ocrEditorControllerProvider = ChangeNotifierProvider.autoDispose.family<OcrEditorController, ScanDocument>((ref, doc) {
  return OcrEditorController(ref, doc);
});

final ocrEditorStateProvider = Provider.autoDispose.family<OcrEditorState, ScanDocument>((ref, doc) {
  // Now ref.watch(controllerProvider) will correctly trigger a rebuild 
  // of this provider whenever notifyListeners() is called in the controller.
  final controller = ref.watch(ocrEditorControllerProvider(doc));
  return controller.state;
});

// -----------------------------------------------------------------------------
// Controller (ChangeNotifier)
// -----------------------------------------------------------------------------

class OcrEditorController extends ChangeNotifier {
  final Ref ref;
  final ScanDocument document;
  
  OcrEditorState _state;
  OcrEditorState get state => _state;

  PdfDocument? _pdfDocument;
  PdfDocument? get pdfDocument => _pdfDocument;

  OcrEditorController(this.ref, this.document) : _state = OcrEditorState(
    textBlocks: document.textBlocks ?? List.generate(document.imagePaths.length, (_) => []),
    imageSizes: document.imageSizes ?? List.filled(document.imagePaths.length, null),
    currentPage: 0,
    showOcrText: true,
    activeFabMode: FabMode.move,
  ) {
    _initPdf();
  }

  Future<void> _initPdf() async {
    if (document.sourcePdfPath != null) {
      try {
        _pdfDocument = await PdfDocument.openFile(document.sourcePdfPath!);
        notifyListeners();
      } catch (e) {
        debugPrint('Error opening source PDF for lazy rendering: $e');
      }
    }
  }

  @override
  void dispose() {
    _pdfDocument?.dispose();
    super.dispose();
  }

  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  final StorageService _storageService = StorageService();

  static const _pageBreakDelimiter = '---PAGE_BREAK---';

  void _updateState(OcrEditorState newState) {
    _state = newState;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void setPage(int index) {
    if (index < 0 || index >= _state.textBlocks.length) return;
    _updateState(_state.copyWith(currentPage: index, clearSelection: true));
  }

  void toggleOcrText() {
    _updateState(_state.copyWith(showOcrText: !_state.showOcrText));
  }

  void setFabMode(FabMode mode) {
    if (_state.activeFabMode == mode) {
      _updateState(_state.copyWith(clearFabMode: true));
    } else {
      _updateState(_state.copyWith(activeFabMode: mode));
    }
  }

  void selectElement(int pageIdx, int bi, int li, int ei) {
    _updateState(_state.copyWith(
      selection: OcrSelection(
        pageIdx: pageIdx,
        blockIdx: bi,
        lineIdx: li,
        elemIdx: ei,
      ),
      boxEditMode: true,
      editModeSnapshot: _deepCopyBlocks(_state.textBlocks),
      editModeUndoStackSize: _state.undoStack.length,
    ));
  }

  void clearSelection() {
    _updateState(_state.copyWith(clearSelection: true, boxEditMode: false));
  }

  void enterBoxEditMode() {
    if (_state.selection == null) return;
    _updateState(_state.copyWith(
      boxEditMode: true,
      editModeSnapshot: _deepCopyBlocks(_state.textBlocks),
      editModeUndoStackSize: _state.undoStack.length,
    ));
  }

  void exitBoxEditModeCancel() {
    if (_state.editModeSnapshot != null) {
      _updateState(_state.copyWith(
        textBlocks: _state.editModeSnapshot,
        clearSelection: true,
        boxEditMode: false,
        clearEditModeSnapshot: true,
      ));
    }
  }

  void exitBoxEditModeOk() {
    _updateState(_state.copyWith(
      clearSelection: true,
      boxEditMode: false,
      clearEditModeSnapshot: true,
    ));
  }

  // ---------------------------------------------------------------------------
  // Element Manipulation
  // ---------------------------------------------------------------------------

  void moveElement(Offset deltaInImagePixels) {
    final sel = _state.selection;
    if (sel == null) return;

    final updatedBlocks = _deepCopyBlocks(_state.textBlocks);
    final block = updatedBlocks[sel.pageIdx][sel.blockIdx];
    final line = block.lines[sel.lineIdx];
    final elem = line.elements[sel.elemIdx];

    line.elements[sel.elemIdx] = OcrTextElement(
      text: elem.text,
      left: elem.left + deltaInImagePixels.dx,
      top: elem.top + deltaInImagePixels.dy,
      width: elem.width,
      height: elem.height,
    );
    _syncBlockBounds(block);

    _updateState(_state.copyWith(textBlocks: updatedBlocks, hasChanges: true));
  }

  void resizeElement(Offset deltaInImagePixels, ResizeHandle handle) {
    final sel = _state.selection;
    if (sel == null) return;

    final updatedBlocks = _deepCopyBlocks(_state.textBlocks);
    final block = updatedBlocks[sel.pageIdx][sel.blockIdx];
    final line = block.lines[sel.lineIdx];
    final elem = line.elements[sel.elemIdx];

    double newLeft = elem.left;
    double newTop = elem.top;
    double newWidth = elem.width;
    double newHeight = elem.height;

    switch (handle) {
      case ResizeHandle.topLeft:
        newLeft += deltaInImagePixels.dx;
        newTop += deltaInImagePixels.dy;
        newWidth -= deltaInImagePixels.dx;
        newHeight -= deltaInImagePixels.dy;
        break;
      case ResizeHandle.topRight:
        newTop += deltaInImagePixels.dy;
        newWidth += deltaInImagePixels.dx;
        newHeight -= deltaInImagePixels.dy;
        break;
      case ResizeHandle.bottomLeft:
        newLeft += deltaInImagePixels.dx;
        newWidth -= deltaInImagePixels.dx;
        newHeight += deltaInImagePixels.dy;
        break;
      case ResizeHandle.bottomRight:
        newWidth += deltaInImagePixels.dx;
        newHeight += deltaInImagePixels.dy;
        break;
    }

    if (newWidth < 5) newWidth = 5;
    if (newHeight < 5) newHeight = 5;

    line.elements[sel.elemIdx] = OcrTextElement(
      text: elem.text,
      left: newLeft,
      top: newTop,
      width: newWidth,
      height: newHeight,
    );
    _syncBlockBounds(block);

    _updateState(_state.copyWith(textBlocks: updatedBlocks, hasChanges: true));
  }

  void deleteSelectedElement() {
    final sel = _state.selection;
    if (sel == null) return;

    _pushUndo();
    final updatedBlocks = _deepCopyBlocks(_state.textBlocks);
    final page = updatedBlocks[sel.pageIdx];
    final block = page[sel.blockIdx];
    final line = block.lines[sel.lineIdx];

    line.elements.removeAt(sel.elemIdx);
    if (line.elements.isEmpty) {
      block.lines.removeAt(sel.lineIdx);
    }
    if (block.lines.isEmpty) {
      page.removeAt(sel.blockIdx);
    } else {
      _syncBlockBounds(block);
    }

    _updateState(_state.copyWith(
      textBlocks: updatedBlocks,
      hasChanges: true,
      clearSelection: true,
      boxEditMode: false,
    ));
  }

  void updateElementText(String newText) {
    final sel = _state.selection;
    if (sel == null) return;

    _pushUndo();
    final updatedBlocks = _deepCopyBlocks(_state.textBlocks);
    final block = updatedBlocks[sel.pageIdx][sel.blockIdx];
    final line = block.lines[sel.lineIdx];
    final elem = line.elements[sel.elemIdx];

    line.elements[sel.elemIdx] = elem.copyWith(text: newText);
    _syncBlockLinesText(block);

    _updateState(_state.copyWith(textBlocks: updatedBlocks, hasChanges: true));
  }


  // ---------------------------------------------------------------------------
  // Coordinate Systems & Hit Testing
  // ---------------------------------------------------------------------------

  // In the new simplified model, scenePos is ALREADY in image pixels.
  BoxHit? hitTestElement(Offset scenePos, int pageIdx) {
    final pageBlocks = _state.textBlocks[pageIdx];
    
    for (var bi = pageBlocks.length - 1; bi >= 0; bi--) {
      final block = pageBlocks[bi];
      for (var li = 0; li < block.lines.length; li++) {
        final line = block.lines[li];
        for (var ei = 0; ei < line.elements.length; ei++) {
          final el = line.elements[ei];
          final rect = Rect.fromLTWH(el.left, el.top, el.width, el.height);
          if (rect.contains(scenePos)) {
            return BoxHit(bi: bi, li: li, ei: ei, element: el);
          }
        }
      }
    }
    return null;
  }

  ResizeHandle? hitTestResizeHandle(Offset scenePos, OcrTextElement el) {
    const handleSize = 24.0;
    
    final handles = {
      ResizeHandle.topLeft: Offset(el.left, el.top),
      ResizeHandle.topRight: Offset(el.left + el.width, el.top),
      ResizeHandle.bottomLeft: Offset(el.left, el.top + el.height),
      ResizeHandle.bottomRight: Offset(el.left + el.width, el.top + el.height),
    };

    for (var entry in handles.entries) {
      final rect = Rect.fromCenter(center: entry.value, width: handleSize, height: handleSize);
      if (rect.contains(scenePos)) return entry.key;
    }
    return null;
  }

  void updateImageSize(int index, Size size) {
    if (index < 0 || index >= _state.imageSizes.length) return;
    if (_state.imageSizes[index] == size) return;
    
    final newSizes = List<Size?>.from(_state.imageSizes);
    newSizes[index] = size;
    _updateState(_state.copyWith(imageSizes: newSizes));
  }

  void addBoxAtCenter(Matrix4 transformation, double viewportW, double viewportH) {
    final imgSize = _state.imageSizes[_state.currentPage];
    if (imgSize == null) return;

    _pushUndo();
    final oldBlocks = _deepCopyBlocks(_state.textBlocks);

    // 1. Viewport center (now relative to the body, no AppBar adjustment needed)
    final viewportCenter = Offset(viewportW / 2, viewportH / 2);
    
    // 2. Convert to "fitted scene" center (child of InteractiveViewer is Center)
    final sceneCenterFitted = transformation.toScene(viewportCenter);
    
    // 3. Calculate pixelToScreen (fitting factor)
    final scaleW = viewportW / imgSize.width;
    final scaleH = viewportH / imgSize.height;
    final pixelToScreen = scaleW < scaleH ? scaleW : scaleH;
    
    // 4. Calculate the offset of the image within the Center widget
    final fittedW = imgSize.width * pixelToScreen;
    final fittedH = imgSize.height * pixelToScreen;
    final offsetX = (viewportW - fittedW) / 2;
    final offsetY = (viewportH - fittedH) / 2;

    // 5. Convert to raw image pixels
    final sceneCenterPixels = Offset(
      (sceneCenterFitted.dx - offsetX) / pixelToScreen,
      (sceneCenterFitted.dy - offsetY) / pixelToScreen,
    );

    const boxW = 100.0;
    const boxH = 40.0;

    final newElement = OcrTextElement(
      text: '',
      left: sceneCenterPixels.dx - boxW / 2,
      top: sceneCenterPixels.dy - boxH / 2,
      width: boxW,
      height: boxH,
    );

    final newLine = OcrTextLine(text: '', elements: [newElement]);
    final newBlock = OcrTextBlock(
      text: '',
      left: newElement.left,
      top: newElement.top,
      width: newElement.width,
      height: newElement.height,
      lines: [newLine],
    );

    final updatedBlocks = _deepCopyBlocks(_state.textBlocks);
    updatedBlocks[_state.currentPage].add(newBlock);

    _updateState(_state.copyWith(
      textBlocks: updatedBlocks,
      hasChanges: true,
      selection: OcrSelection(
        pageIdx: _state.currentPage,
        blockIdx: updatedBlocks[_state.currentPage].length - 1,
        lineIdx: 0,
        elemIdx: 0,
      ),
      boxEditMode: true,
      editModeSnapshot: oldBlocks,
    ));
  }

  // ---------------------------------------------------------------------------
  // Save Changes
  // ---------------------------------------------------------------------------

  Future<ScanDocument?> saveChanges(ScanDocument document) async {
    if (!_state.hasChanges) return null;

    _updateState(_state.copyWith(isSaving: true));

    try {
      final updatedOcrText = _state.textBlocks
          .map((blocks) => blocks.map((b) => b.text).join('\n'))
          .join(_pageBreakDelimiter);

      final oldPdfPath = document.pdfPath;
      final newPdfPath = await _pdfService.generateSearchablePdf(
        imagePaths: document.imagePaths,
        textBlocks: _state.textBlocks,
        title: document.title,
      );

      if (oldPdfPath != null) {
        try {
          final oldPdf = File(oldPdfPath);
          if (await oldPdf.exists()) await oldPdf.delete();
        } catch (_) {}
      }

      final updated = document.copyWith(
        ocrText: updatedOcrText,
        textBlocks: _state.textBlocks,
        pdfPath: newPdfPath,
        updatedAt: DateTime.now(),
      );
      await _storageService.saveDocument(updated);

      _updateState(_state.copyWith(isSaving: false, hasChanges: false));
      return updated;
    } catch (e) {
      _updateState(_state.copyWith(isSaving: false));
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Undo / Redo
  // ---------------------------------------------------------------------------

  void _pushUndo() {
    final currentBlocks = _deepCopyBlocks(_state.textBlocks);
    _updateState(_state.copyWith(
      undoStack: [..._state.undoStack, currentBlocks],
      redoStack: [],
    ));
  }

  void undo() {
    if (_state.undoStack.isEmpty) return;

    final newUndo = List<List<List<OcrTextBlock>>>.from(_state.undoStack);
    final last = newUndo.removeLast();
    
    _updateState(_state.copyWith(
      redoStack: [..._state.redoStack, _deepCopyBlocks(_state.textBlocks)],
      textBlocks: last,
      undoStack: newUndo,
      hasChanges: newUndo.isNotEmpty,
      clearSelection: true,
      boxEditMode: false,
    ));
  }

  void redo() {
    if (_state.redoStack.isEmpty) return;

    final newRedo = List<List<List<OcrTextBlock>>>.from(_state.redoStack);
    final last = newRedo.removeLast();

    _updateState(_state.copyWith(
      undoStack: [..._state.undoStack, _deepCopyBlocks(_state.textBlocks)],
      textBlocks: last,
      redoStack: newRedo,
      hasChanges: true,
      clearSelection: true,
      boxEditMode: false,
    ));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _syncBlockBounds(OcrTextBlock block) {}

  void _syncBlockLinesText(OcrTextBlock block) {}

  List<List<OcrTextBlock>> _deepCopyBlocks(List<List<OcrTextBlock>> blocks) {
    return blocks.map((page) => page.map((block) => block.copyWith(
      lines: block.lines.map((line) => line.copyWith(
        elements: line.elements.map((el) => el.copyWith()).toList(),
      )).toList(),
    )).toList()).toList();
  }
}

enum ResizeHandle { topLeft, topRight, bottomLeft, bottomRight }

extension Matrix4ToScene on Matrix4 {
  Offset toScene(Offset viewportPoint) {
    final inverse = Matrix4.inverted(this);
    final untransformed = inverse.transform3(v64.Vector3(viewportPoint.dx, viewportPoint.dy, 0));
    return Offset(untransformed.x, untransformed.y);
  }
}
