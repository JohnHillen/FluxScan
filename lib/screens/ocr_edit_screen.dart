import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ocr_editor/ocr_editor_notifier.dart';
import 'ocr_editor/widgets/ocr_page_view.dart';
import 'ocr_editor/widgets/ocr_editor_toolbar.dart';
import '../models/scan_document.dart';

class OcrEditScreen extends ConsumerStatefulWidget {
  final ScanDocument document;
  const OcrEditScreen({super.key, required this.document});

  @override
  ConsumerState<OcrEditScreen> createState() => _OcrEditScreenState();
}

class _OcrEditScreenState extends ConsumerState<OcrEditScreen> {
  final TransformationController _transformationController = TransformationController();
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _transformationController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _firstPage(OcrEditorController controller) {
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
      controller.setPage(0);
    }
  }

  void _lastPage(OcrEditorController controller) {
    if (_pageController.hasClients) {
      final lastIdx = widget.document.imagePaths.length - 1;
      _pageController.animateToPage(
        lastIdx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
      controller.setPage(lastIdx);
    }
  }

  void _jumpToPage(OcrEditorController controller, int pageIndex) {
    if (_pageController.hasClients) {
      _pageController.jumpToPage(pageIndex);
      controller.setPage(pageIndex);
    }
  }

  Future<void> _showJumpToPageDialog(OcrEditorController controller, int totalPages) async {
    final textController = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Seite springen'),
        content: TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Seitennummer (1-$totalPages)',
            hintText: 'Z.B. 42',
          ),
          onSubmitted: (value) {
            final page = int.tryParse(value);
            if (page != null && page >= 1 && page <= totalPages) {
              Navigator.of(context).pop(page - 1);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () {
              final page = int.tryParse(textController.text);
              if (page != null && page >= 1 && page <= totalPages) {
                Navigator.of(context).pop(page - 1);
              }
            },
            child: const Text('Springen'),
          ),
        ],
      ),
    );

    if (result != null) {
      _jumpToPage(controller, result);
    }
  }

  void _previousPage(OcrEditorController controller) {
    if (_pageController.hasClients && _pageController.page! > 0) {
      final newPage = (_pageController.page! - 1).round();
      _pageController.animateToPage(
        newPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      // Update state immediately for the UI
      controller.setPage(newPage);
    }
  }

  void _nextPage(OcrEditorController controller) {
    if (_pageController.hasClients && _pageController.page! < widget.document.imagePaths.length - 1) {
      final newPage = (_pageController.page! + 1).round();
      _pageController.animateToPage(
        newPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      // Update state immediately for the UI
      controller.setPage(newPage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ocrEditorStateProvider(widget.document));
    final controller = ref.read(ocrEditorControllerProvider(widget.document));
    final hasMultiplePages = widget.document.imagePaths.length > 1;

    return PopScope(
      canPop: !state.hasChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        final decision = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Änderungen speichern?'),
            content: const Text(
                'Sie haben ungespeicherte Änderungen am OCR-Text oder den Boxen. Möchten Sie diese speichern oder verwerfen?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Verwerfen'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Speichern'),
              ),
            ],
          ),
        );

        if (!context.mounted) return;

        if (decision == 'discard') {
          Navigator.of(context).pop();
        } else if (decision == 'save') {
          final updated = await controller.saveChanges(widget.document);
          if (context.mounted) {
            Navigator.of(context).pop(updated);
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: Text(widget.document.title),
          actions: [
            IconButton(
              icon: Icon(
                  state.showOcrText ? Icons.visibility : Icons.visibility_off),
              onPressed: controller.toggleOcrText,
              tooltip: 'OCR-Text umschalten',
            ),
            IconButton(
              icon: const Icon(Icons.undo),
              onPressed: state.undoStack.isNotEmpty ? controller.undo : null,
            ),
            IconButton(
              icon: const Icon(Icons.redo),
              onPressed: state.redoStack.isNotEmpty ? controller.redo : null,
            ),
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: state.hasChanges
                  ? () async {
                      final updated =
                          await controller.saveChanges(widget.document);
                      if (updated != null && mounted) {
                        Navigator.pop(context, updated);
                      }
                    }
                  : null,
            ),
          ],
        ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize = constraints.biggest;
          
          return Stack(
            children: [
              OcrPageView(
                document: widget.document,
                transformationController: _transformationController,
                pageController: _pageController,
                availableWidth: viewportSize.width,
                availableHeight: viewportSize.height,
              ),
              
              // Navigation & Action Buttons (Bottom Bar)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Left: Undo/Redo or Spacer (Optional, currently spacer)
                    const Opacity(
                      opacity: 0,
                      child: FloatingActionButton.small(onPressed: null, child: Icon(Icons.add)),
                    ),
                    
                    // Center: Page Navigation
                    if (hasMultiplePages)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // First Page
                          FloatingActionButton.small(
                            heroTag: 'first_page',
                            onPressed: state.currentPage > 0 ? () => _firstPage(controller) : null,
                            backgroundColor: state.currentPage > 0 ? null : Colors.grey.withValues(alpha: 0.5),
                            child: const Icon(Icons.first_page),
                          ),
                          const SizedBox(width: 8),
                          // Prev Page
                          FloatingActionButton.small(
                            heroTag: 'prev_page',
                            onPressed: state.currentPage > 0 ? () => _previousPage(controller) : null,
                            backgroundColor: state.currentPage > 0 ? null : Colors.grey.withValues(alpha: 0.5),
                            child: const Icon(Icons.chevron_left),
                          ),
                          const SizedBox(width: 8),
                          
                          // Page Label (Clickable to jump)
                          GestureDetector(
                            onTap: () => _showJumpToPageDialog(controller, widget.document.imagePaths.length),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white24, width: 1),
                              ),
                              child: Text(
                                'Seite ${state.currentPage + 1} / ${widget.document.imagePaths.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          
                          // Next Page
                          FloatingActionButton.small(
                            heroTag: 'next_page',
                            onPressed: state.currentPage < widget.document.imagePaths.length - 1 ? () => _nextPage(controller) : null,
                            backgroundColor: state.currentPage < widget.document.imagePaths.length - 1 ? null : Colors.grey.withValues(alpha: 0.5),
                            child: const Icon(Icons.chevron_right),
                          ),
                          const SizedBox(width: 8),
                          // Last Page
                          FloatingActionButton.small(
                            heroTag: 'last_page',
                            onPressed: state.currentPage < widget.document.imagePaths.length - 1 ? () => _lastPage(controller) : null,
                            backgroundColor: state.currentPage < widget.document.imagePaths.length - 1 ? null : Colors.grey.withValues(alpha: 0.5),
                            child: const Icon(Icons.last_page),
                          ),
                        ],
                      )
                    else
                      const Spacer(),

                    // Right: Actions (Add Box OR Ok/Cancel)
                    if (!state.boxEditMode)
                      FloatingActionButton.extended(
                        heroTag: 'add_box',
                        onPressed: () {
                          controller.addBoxAtCenter(
                            _transformationController.value,
                            viewportSize.width,
                            viewportSize.height,
                          );
                        },
                        icon: const Icon(Icons.add_box),
                        label: const Text('Box'),
                      )
                    else
                      // Reuse OcrEditorToolbar for the Ok/Cancel logic
                      OcrEditorToolbar(
                        document: widget.document,
                      ),
                  ],
                ),
              ),

              if (state.isSaving)
                Container(
                  color: Colors.black54,
                  child: const Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
      ),
      ),
    );
  }
}
