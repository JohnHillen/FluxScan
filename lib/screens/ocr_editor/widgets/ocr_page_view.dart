import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../providers/settings_provider.dart';
import '../ocr_editor_notifier.dart';
import '../ocr_editor_state.dart';
import '../../../models/scan_document.dart';
import '../../../widgets/pdf_lazy_image.dart';

class OcrPageView extends ConsumerStatefulWidget {
  final ScanDocument document;
  final TransformationController? transformationController;
  final PageController? pageController;
  final double? availableWidth;
  final double? availableHeight;

  const OcrPageView({
    super.key,
    required this.document,
    this.transformationController,
    this.pageController,
    this.availableWidth,
    this.availableHeight,
  });

  @override
  ConsumerState<OcrPageView> createState() => _OcrPageViewState();
}

class _OcrPageViewState extends ConsumerState<OcrPageView> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    final state = ref.read(ocrEditorStateProvider(widget.document));
    _pageController =
        widget.pageController ?? PageController(initialPage: state.currentPage);
  }

  @override
  void dispose() {
    // Only dispose if we created it
    if (widget.pageController == null) {
      _pageController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ocrEditorStateProvider(widget.document));
    final controller = ref.watch(ocrEditorControllerProvider(widget.document));
    final settings = ref.watch(settingsProvider);

    // Listen for external page changes (e.g. from the thumbnail list)
    ref.listen(
        ocrEditorStateProvider(widget.document).select((s) => s.currentPage),
        (prev, next) {
      if (_pageController.hasClients && _pageController.page?.round() != next) {
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });

    return Container(
      color: Colors.black.withOpacity(0.05),
      child: PageView.builder(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: widget.document.imagePaths.length,
        onPageChanged: (index) => controller.setPage(index),
        itemBuilder: (context, index) {
          final imagePath = widget.document.imagePaths[index];

          return FutureBuilder<Size>(
            future: _getImageSize(imagePath, index),
            builder: (context, sizeSnapshot) {
              if (!sizeSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final imageSize = sizeSnapshot.data!;

              return LayoutBuilder(
                builder: (context, constraints) {
                  final availWidth = widget.availableWidth ?? constraints.maxWidth;
                  final availHeight = widget.availableHeight ?? constraints.maxHeight;

                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: InteractiveViewer(
                        transformationController:
                            widget.transformationController ??
                                TransformationController(),
                        minScale: 1.0,
                        maxScale: 10.0,
                        panEnabled: true,
                        scaleEnabled: true,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: AspectRatio(
                            aspectRatio: imageSize.width / imageSize.height,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final pixelToScreen =
                                    constraints.maxWidth / imageSize.width;
                                return Stack(
                                  children: [
                                    GestureDetector(
                                      onTap: () => controller.clearSelection(),
                                      child: _buildPageImage(
                                        context,
                                        ref,
                                        controller,
                                        index,
                                        pixelToScreen,
                                        imageSize,
                                      ),
                                    ),
                                    _OverlayLayer(
                                      document: widget.document,
                                      pageIdx: index,
                                      pixelToScreen: pixelToScreen,
                                      transformationController:
                                          widget.transformationController ??
                                              TransformationController(),
                                      ocrTextColor: settings.ocrTextColor,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<Size> _getImageSize(String path, int index) async {
    // Priority 1: Use actual image file if it exists (Ground Truth)
    if (path.isNotEmpty) {
      try {
        final bytes = await File(path).readAsBytes();
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        final size =
            Size(descriptor.width.toDouble(), descriptor.height.toDouble());
        descriptor.dispose();
        buffer.dispose();
        if (size.width > 0 && size.height > 0) {
          return size;
        }
      } catch (e) {
        debugPrint('Error getting size from file $path: $e');
      }
    }

    // Priority 2: Use persisted image sizes
    if (widget.document.imageSizes != null &&
        widget.document.imageSizes!.length > index &&
        widget.document.imageSizes![index] != null) {
      final size = widget.document.imageSizes![index]!;
      if (size.width > 0 && size.height > 0) {
        return size;
      }
    }

    // Fallback: A4
    return const Size(2480, 3508);
  }

  Widget _buildPageImage(
    BuildContext context,
    WidgetRef ref,
    OcrEditorController controller,
    int index,
    double pixelToScreen,
    Size imageSize,
  ) {
    final imagePath = widget.document.imagePaths[index];

    if (imagePath.isNotEmpty) {
      return Image.file(
        File(imagePath),
        width: imageSize.width * pixelToScreen,
        height: imageSize.height * pixelToScreen,
        fit: BoxFit.contain,
        alignment: Alignment.center,
        filterQuality: FilterQuality.medium,
      );
    }

    final pdfDoc = controller.pdfDocument;

    if (pdfDoc == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return PdfLazyImage(
      pdfDocument: pdfDoc,
      pageIndex: index,
      fit: BoxFit.contain,
    );
  }
}

class _OverlayLayer extends ConsumerWidget {
  final ScanDocument document;
  final int pageIdx;
  final double pixelToScreen;
  final TransformationController transformationController;
  final Color ocrTextColor;

  const _OverlayLayer({
    required this.document,
    required this.pageIdx,
    required this.pixelToScreen,
    required this.transformationController,
    required this.ocrTextColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ocrEditorStateProvider(document));

    if (!state.showOcrText) return const SizedBox.shrink();

    return Stack(
      children: [
        for (int bi = 0; bi < state.textBlocks[pageIdx].length; bi++)
          for (int li = 0;
              li < state.textBlocks[pageIdx][bi].lines.length;
              li++)
            for (int ei = 0;
                ei < state.textBlocks[pageIdx][bi].lines[li].elements.length;
                ei++)
              _InteractiveWordBox(
                document: document,
                pageIdx: pageIdx,
                blockIdx: bi,
                lineIdx: li,
                elemIdx: ei,
                pixelToScreen: pixelToScreen,
                ocrTextColor: ocrTextColor,
                transformationController: transformationController,
              ),
        // Global Resize Handles for the selected element
        if (state.selection != null &&
            state.selection!.pageIdx == pageIdx &&
            state.boxEditMode &&
            state.activeFabMode == FabMode.scale)
          _SelectionHandles(
            document: document,
            pixelToScreen: pixelToScreen,
            transformationController: transformationController,
          ),
      ],
    );
  }
}

class _SelectionHandles extends ConsumerWidget {
  final ScanDocument document;
  final double pixelToScreen;
  final TransformationController transformationController;

  const _SelectionHandles({
    required this.document,
    required this.pixelToScreen,
    required this.transformationController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ocrEditorStateProvider(document));
    final sel = state.selection!;
    final element =
        state.textBlocks[sel.pageIdx][sel.blockIdx].lines[sel.lineIdx].elements[sel.elemIdx];

    final left = element.left * pixelToScreen;
    final top = element.top * pixelToScreen;
    final width = element.width * pixelToScreen;
    final height = element.height * pixelToScreen;

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _ResizeHandle(
            handle: ResizeHandle.topLeft,
            document: document,
            pixelToScreen: pixelToScreen,
            transformationController: transformationController,
            rect: Rect.fromLTWH(left, top, width, height),
          ),
          _ResizeHandle(
            handle: ResizeHandle.topRight,
            document: document,
            pixelToScreen: pixelToScreen,
            transformationController: transformationController,
            rect: Rect.fromLTWH(left, top, width, height),
          ),
          _ResizeHandle(
            handle: ResizeHandle.bottomLeft,
            document: document,
            pixelToScreen: pixelToScreen,
            transformationController: transformationController,
            rect: Rect.fromLTWH(left, top, width, height),
          ),
          _ResizeHandle(
            handle: ResizeHandle.bottomRight,
            document: document,
            pixelToScreen: pixelToScreen,
            transformationController: transformationController,
            rect: Rect.fromLTWH(left, top, width, height),
          ),
        ],
      ),
    );
  }
}

class _InteractiveWordBox extends ConsumerWidget {
  final ScanDocument document;
  final int pageIdx;
  final int blockIdx;
  final int lineIdx;
  final int elemIdx;
  final double pixelToScreen;
  final Color ocrTextColor;
  final TransformationController transformationController;

  const _InteractiveWordBox({
    required this.document,
    required this.pageIdx,
    required this.blockIdx,
    required this.lineIdx,
    required this.elemIdx,
    required this.pixelToScreen,
    required this.ocrTextColor,
    required this.transformationController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ocrEditorStateProvider(document));
    final controller = ref.read(ocrEditorControllerProvider(document));

    final element =
        state.textBlocks[pageIdx][blockIdx].lines[lineIdx].elements[elemIdx];
    final isSelected = state.selection?.pageIdx == pageIdx &&
        state.selection?.blockIdx == blockIdx &&
        state.selection?.lineIdx == lineIdx &&
        state.selection?.elemIdx == elemIdx;

    final left = element.left * pixelToScreen;
    final top = element.top * pixelToScreen;
    final width = element.width * pixelToScreen;
    final height = element.height * pixelToScreen;

    // Note: details.delta is already in scene pixels (framework handles IV transform)
    // We only need to convert from scene to image pixels.

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: () =>
            controller.selectElement(pageIdx, blockIdx, lineIdx, elemIdx),
        onPanUpdate: isSelected && state.activeFabMode == FabMode.move
            ? (details) =>
                controller.moveElement(details.delta / pixelToScreen)
            : null,
        child: Container(
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.deepOrange.withOpacity(0.3)
                : Colors.teal.withOpacity(0.15),
            border: Border.all(
              color:
                  isSelected ? Colors.deepOrange : Colors.teal.withOpacity(0.5),
              width: isSelected ? 2 : 0.5,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // OCR Text
              Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Padding(
                    padding: const EdgeInsets.all(1.0),
                    child: Text(
                      element.text,
                      style: TextStyle(
                        fontSize: 10, // Base size, scaled by FittedBox
                        color: isSelected ? Colors.black : ocrTextColor,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResizeHandle extends ConsumerWidget {
  final ResizeHandle handle;
  final ScanDocument document;
  final double pixelToScreen;
  final TransformationController transformationController;
  final Rect rect;

  const _ResizeHandle({
    required this.handle,
    required this.document,
    required this.pixelToScreen,
    required this.transformationController,
    required this.rect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    double hLeft = 0, hTop = 0;
    const double hOffset = 12.0; // Half of handle size (24)
    const double extraOffset = 12.0; // Move them diagonally outwards

    switch (handle) {
      case ResizeHandle.topLeft:
        hLeft = rect.left - hOffset - extraOffset;
        hTop = rect.top - hOffset - extraOffset;
        break;
      case ResizeHandle.topRight:
        hLeft = rect.right - hOffset + extraOffset;
        hTop = rect.top - hOffset - extraOffset;
        break;
      case ResizeHandle.bottomLeft:
        hLeft = rect.left - hOffset - extraOffset;
        hTop = rect.bottom - hOffset + extraOffset;
        break;
      case ResizeHandle.bottomRight:
        hLeft = rect.right - hOffset + extraOffset;
        hTop = rect.bottom - hOffset + extraOffset;
        break;
    }

    // Note: details.delta is already in scene pixels (framework handles IV transform)
    return Positioned(
      left: hLeft,
      top: hTop,
      child: GestureDetector(
        onPanUpdate: (details) {
          final controller = ref.read(ocrEditorControllerProvider(document));
          controller.resizeElement(
            details.delta / pixelToScreen,
            handle,
          );
        },
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.deepOrange,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: const Center(
            child: Icon(Icons.zoom_out_map, size: 12, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
