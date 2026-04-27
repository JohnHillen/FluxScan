import 'package:flutter/material.dart';
import '../../../services/scanner_service.dart';

/// Active FAB interaction mode.
enum FabMode { move, scale }

const kMinHandleSpread = 40.0;

/// Result of a bounding box hit test.
class BoxHit {
  final int bi; // block index
  final int li; // line index
  final int ei; // element index
  final OcrTextElement element;

  const BoxHit({
    required this.bi,
    required this.li,
    required this.ei,
    required this.element,
  });
}

/// Selection identifier for a specific element.
class OcrSelection {
  final int pageIdx;
  final int blockIdx;
  final int lineIdx;
  final int elemIdx;

  const OcrSelection({
    required this.pageIdx,
    required this.blockIdx,
    required this.lineIdx,
    required this.elemIdx,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OcrSelection &&
        other.pageIdx == pageIdx &&
        other.blockIdx == blockIdx &&
        other.lineIdx == lineIdx &&
        other.elemIdx == elemIdx;
  }

  @override
  int get hashCode => Object.hash(pageIdx, blockIdx, lineIdx, elemIdx);
}
/// Immutable state for the OCR Editor session.
class OcrEditorState {
  final List<List<OcrTextBlock>> textBlocks;
  final List<Size?> imageSizes;
  final int currentPage;
  
  // Selection
  final OcrSelection? selection;
  
  // UI Flags
  final bool hasChanges;
  final bool isSaving;
  final bool showOcrText;
  final bool isZoomed;
  final bool boxEditMode;
  final FabMode? activeFabMode;

  // History
  final List<List<List<OcrTextBlock>>> undoStack;
  final List<List<List<OcrTextBlock>>> redoStack;

  // Edit Session Sub-state
  final List<List<OcrTextBlock>>? editModeSnapshot;
  final int editModeUndoStackSize;

  const OcrEditorState({
    required this.textBlocks,
    required this.imageSizes,
    this.currentPage = 0,
    this.selection,
    this.hasChanges = false,
    this.isSaving = false,
    this.showOcrText = false,
    this.isZoomed = false,
    this.boxEditMode = false,
    this.activeFabMode,
    this.undoStack = const [],
    this.redoStack = const [],
    this.editModeSnapshot,
    this.editModeUndoStackSize = 0,
  });

  OcrEditorState copyWith({
    List<List<OcrTextBlock>>? textBlocks,
    List<Size?>? imageSizes,
    int? currentPage,
    OcrSelection? selection,
    bool clearSelection = false,
    bool? hasChanges,
    bool? isSaving,
    bool? showOcrText,
    bool? isZoomed,
    bool? boxEditMode,
    FabMode? activeFabMode,
    bool clearFabMode = false,
    List<List<List<OcrTextBlock>>>? undoStack,
    List<List<List<OcrTextBlock>>>? redoStack,
    List<List<OcrTextBlock>>? editModeSnapshot,
    bool clearEditModeSnapshot = false,
    int? editModeUndoStackSize,
  }) {
    return OcrEditorState(
      textBlocks: textBlocks ?? this.textBlocks,
      imageSizes: imageSizes ?? this.imageSizes,
      currentPage: currentPage ?? this.currentPage,
      selection: clearSelection ? null : (selection ?? this.selection),
      hasChanges: hasChanges ?? this.hasChanges,
      isSaving: isSaving ?? this.isSaving,
      showOcrText: showOcrText ?? this.showOcrText,
      isZoomed: isZoomed ?? this.isZoomed,
      boxEditMode: boxEditMode ?? this.boxEditMode,
      activeFabMode: clearFabMode ? null : (activeFabMode ?? this.activeFabMode),
      undoStack: undoStack ?? this.undoStack,
      redoStack: redoStack ?? this.redoStack,
      editModeSnapshot: clearEditModeSnapshot ? null : (editModeSnapshot ?? this.editModeSnapshot),
      editModeUndoStackSize: editModeUndoStackSize ?? this.editModeUndoStackSize,
    );
  }
}
