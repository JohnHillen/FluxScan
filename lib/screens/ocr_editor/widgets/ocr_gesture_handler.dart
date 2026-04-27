import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/scan_document.dart';
import '../ocr_editor_notifier.dart';
import '../ocr_editor_state.dart';

class OcrGestureHandler extends ConsumerStatefulWidget {
  final ScanDocument document;
  final int pageIdx;
  final double pixelToScreen;
  final Widget child;

  const OcrGestureHandler({
    super.key,
    required this.document,
    required this.pageIdx,
    required this.pixelToScreen,
    required this.child,
  });

  @override
  ConsumerState<OcrGestureHandler> createState() => _OcrGestureHandlerState();
}

class _OcrGestureHandlerState extends ConsumerState<OcrGestureHandler> {
  Offset? _dragStartScene;
  ResizeHandle? _activeResizeHandle;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ocrEditorStateProvider(widget.document));
    final controller = ref.read(ocrEditorControllerProvider(widget.document));

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (details) {
        // Convert local scene coordinates to image pixels
        final scenePos = details.localPosition / widget.pixelToScreen;
        
        // 1. Check for resize handles if in boxEditMode
        if (state.boxEditMode && state.selection != null) {
          final sel = state.selection!;
          if (sel.pageIdx == widget.pageIdx) {
            final block = state.textBlocks[sel.pageIdx][sel.blockIdx];
            final elem = block.lines[sel.lineIdx].elements[sel.elemIdx];
            final handle = controller.hitTestResizeHandle(scenePos, elem);
            if (handle != null) {
              _activeResizeHandle = handle;
              return;
            }
          }
        }

        // 2. Normal hit test
        final hit = controller.hitTestElement(scenePos, widget.pageIdx);

        if (hit != null) {
          controller.selectElement(widget.pageIdx, hit.bi, hit.li, hit.ei);
          if (state.activeFabMode == FabMode.move || state.activeFabMode == FabMode.scale) {
            controller.enterBoxEditMode();
          }
        } else {
          controller.clearSelection();
        }
      },
      onPanStart: (details) {
        if (state.activeFabMode == null) return;

        // Convert local scene coordinates to image pixels
        final scenePos = details.localPosition / widget.pixelToScreen;
        
        if (state.boxEditMode && state.selection != null) {
          final sel = state.selection!;
          final block = state.textBlocks[sel.pageIdx][sel.blockIdx];
          final elem = block.lines[sel.lineIdx].elements[sel.elemIdx];
          
          final hit = controller.hitTestElement(scenePos, widget.pageIdx);
          final handle = controller.hitTestResizeHandle(scenePos, elem);
          
          if (handle != null || (hit != null && hit.bi == sel.blockIdx)) {
            _dragStartScene = scenePos;
            _activeResizeHandle = handle;
          }
        }
      },
      onPanUpdate: (details) {
        if (_dragStartScene == null || state.activeFabMode == null) return;
        
        final currentScene = details.localPosition / widget.pixelToScreen;
        final delta = currentScene - _dragStartScene!;
        _dragStartScene = currentScene;

        final controller = ref.read(ocrEditorControllerProvider(widget.document));

        if (_activeResizeHandle != null) {
          controller.resizeElement(delta, _activeResizeHandle!);
        } else {
          controller.moveElement(delta);
        }
      },
      onPanEnd: (_) {
        _dragStartScene = null;
        _activeResizeHandle = null;
      },
      child: widget.child,
    );
  }
}
