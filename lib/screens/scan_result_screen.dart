import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdfrx/pdfrx.dart';

import '../widgets/pdf_lazy_image.dart';

import '../models/scan_document.dart';
import '../services/scanner_service.dart';
import '../services/storage_service.dart';
import '../utils/filename_utils.dart';
import 'ocr_edit_screen.dart';

/// Screen for viewing the details of a scanned document.
///
/// Displays page images and provides options to edit OCR text, rename,
/// share or print the generated PDF.
class ScanResultScreen extends StatefulWidget {
  final ScanDocument document;

  const ScanResultScreen({super.key, required this.document});

  @override
  State<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends State<ScanResultScreen> {
  final StorageService _storageService = StorageService();
  late ScanDocument _document;
  late final PageController _pageController;
  int _currentPage = 0;
  bool _isMenuOpen = false;
  PdfDocument? _pdfDocument;

  // Search State
  bool _isSearchActive = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<({int pageIdx, int blockIdx, int lineIdx, int elemIdx})> _searchResults =
      [];
  int _currentResultIndex = -1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _document = widget.document;
    _initPdf();
  }

  Future<void> _initPdf() async {
    if (_document.sourcePdfPath != null) {
      try {
        final doc = await PdfDocument.openFile(_document.sourcePdfPath!);
        if (mounted) setState(() => _pdfDocument = doc);
      } catch (e) {
        debugPrint('Error opening source PDF for result screen: $e');
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _pdfDocument?.dispose();
    super.dispose();
  }

  void _previousPage() {
    if (_pageController.hasClients && _currentPage > 0) {
      _pageController.animateToPage(
        _currentPage - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _nextPage() {
    if (_pageController.hasClients &&
        _currentPage < _document.imagePaths.length - 1) {
      _pageController.animateToPage(
        _currentPage + 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _firstPage() {
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _lastPage() {
    if (_pageController.hasClients) {
      final lastIdx = _document.imagePaths.length - 1;
      _pageController.animateToPage(
        lastIdx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _showJumpToPageDialog() async {
    final totalPages = _document.imagePaths.length;
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

    if (result != null && _pageController.hasClients) {
      _pageController.jumpToPage(result);
    }
  }

  Future<void> _renameDocument() async {
    if (!mounted) return;

    final newTitle = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDocumentDialog(initialTitle: _document.title),
    );

    if (!mounted) return;

    if (newTitle != null &&
        newTitle.isNotEmpty &&
        newTitle != _document.title) {
      final updated = _document.copyWith(
        title: newTitle,
        updatedAt: DateTime.now(),
      );
      await _storageService.saveDocument(updated);
      if (mounted) {
        setState(() => _document = updated);
      }
    }
  }

  Future<void> _sharePdf() async {
    if (_document.pdfPath == null) {
      _showError('No PDF available.');
      return;
    }

    final file = File(_document.pdfPath!);
    if (!await file.exists()) {
      _showError('PDF file not found.');
      return;
    }

    // Copy the PDF to a temp file named after the document title so that
    // the recipient (and the system share sheet) sees a meaningful filename
    // instead of the internal UUID-based storage path.
    final fileName = sanitizedPdfFilename(_document.title);
    final tempDir = await getTemporaryDirectory();
    final tempFile = await File(_document.pdfPath!).copy(
      '${tempDir.path}/$fileName',
    );

    await Share.shareXFiles(
      [XFile(tempFile.path)],
      subject: _document.title,
    );
  }

  Future<void> _printPdf() async {
    if (_document.pdfPath == null) {
      _showError('No PDF available.');
      return;
    }

    final file = File(_document.pdfPath!);
    if (!await file.exists()) {
      _showError('PDF file not found.');
      return;
    }

    final bytes = await file.readAsBytes();
    await Printing.layoutPdf(onLayout: (_) => bytes);
  }

  /// Opens the word-level OCR edit screen and applies any changes the user
  /// saves back to [_document].
  Future<void> _editOcrText() async {
    setState(() => _isMenuOpen = false);
    final updated = await Navigator.of(context).push<ScanDocument>(
      MaterialPageRoute(
        builder: (_) => OcrEditScreen(document: _document),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _document = updated);
    }
  }

  void _showOcrTextSheet() {
    setState(() => _isMenuOpen = false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Colors.grey[900], // Dark background
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: Colors.white10, width: 1),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Erkannter Text',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10),
              Expanded(
                child: SelectionArea(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _document.ocrText,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.5,
                        fontFamily: 'Roboto',
                        color: Colors.white70,
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

  void _performSearch(String query) {
    final queryLower = query.toLowerCase().trim();
    if (queryLower.isEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResults = [];
        _currentResultIndex = -1;
      });
      return;
    }

    final List<({int pageIdx, int blockIdx, int lineIdx, int elemIdx})>
        results = [];
    final textBlocks = _document.textBlocks;
    if (textBlocks != null) {
      for (int p = 0; p < textBlocks.length; p++) {
        for (int b = 0; b < textBlocks[p].length; b++) {
          final block = textBlocks[p][b];
          for (int l = 0; l < block.lines.length; l++) {
            final line = block.lines[l];
            for (int e = 0; e < line.elements.length; e++) {
              final elem = line.elements[e];
              if (elem.text.toLowerCase().contains(queryLower)) {
                results.add((pageIdx: p, blockIdx: b, lineIdx: l, elemIdx: e));
              }
            }
          }
        }
      }
    }

    setState(() {
      _searchQuery = queryLower;
      _searchResults = results;
      _currentResultIndex = results.isNotEmpty ? 0 : -1;
    });

    if (results.isNotEmpty) {
      _jumpToResult(0);
    }
  }

  void _jumpToResult(int index) {
    if (index < 0 || index >= _searchResults.length) return;
    final match = _searchResults[index];
    setState(() => _currentResultIndex = index);

    if (_pageController.hasClients && _currentPage != match.pageIdx) {
      _pageController.jumpToPage(match.pageIdx);
    }
  }

  void _nextResult() {
    if (_searchResults.isEmpty) return;
    final nextIdx = (_currentResultIndex + 1) % _searchResults.length;
    _jumpToResult(nextIdx);
  }

  void _prevResult() {
    if (_searchResults.isEmpty) return;
    final prevIdx = (_currentResultIndex - 1 + _searchResults.length) %
        _searchResults.length;
    _jumpToResult(prevIdx);
  }

  void _toggleSearch() {
    setState(() {
      _isSearchActive = !_isSearchActive;
      if (!_isSearchActive) {
        _searchController.clear();
        _performSearch('');
      }
    });
  }

  void _showError(String message) {
    debugPrint('Error: $message');
    // Disabled as per user request to not block the UI
    /*
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
    */
  }

  Future<Size> _getImageSize(String path, int pageIndex) async {
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

    // Priority 2: Use persisted image sizes as fallback
    if (_document.imageSizes != null &&
        _document.imageSizes!.length > pageIndex &&
        _document.imageSizes![pageIndex] != null) {
      final size = _document.imageSizes![pageIndex]!;
      if (size.width > 0 && size.height > 0) {
        return size;
      }
    }

    // Priority 3: Use PDF dimensions directly (for lazy rendering)
    if (path.isEmpty) {
      if (_pdfDocument == null) {
        // Wait up to 500ms for PDF to initialize
        for (int i = 0; i < 5; i++) {
          if (_pdfDocument != null) break;
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }

      if (_pdfDocument != null && _pdfDocument!.pages.length > pageIndex) {
        final page = _pdfDocument!.pages[pageIndex];
        return Size(page.width * 3.0, page.height * 3.0);
      }
    }

    // Fallback
    return const Size(2480, 3508);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _isSearchActive
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _toggleSearch,
              )
            : null,
        title: _isSearchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Suchen...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: _performSearch,
              )
            : Text(_document.title),
        actions: [
          if (_isSearchActive) ...[
            if (_searchResults.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    '${_currentResultIndex + 1} / ${_searchResults.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: _searchResults.isNotEmpty ? _prevResult : null,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _searchResults.isNotEmpty ? _nextResult : null,
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _toggleSearch,
            ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),

          // Background Dim for Menu
          if (_isMenuOpen)
            GestureDetector(
              onTap: () => setState(() => _isMenuOpen = false),
              child: Container(
                color: Colors.black54,
              ),
            ),

          // Action Menu (Bottom Right)
          _buildActionMenu(),
        ],
      ),
    );
  }

  Widget _buildActionMenu() {
    return Positioned(
      right: 16,
      bottom: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_isMenuOpen) ...[
            _MenuAction(
              icon: Icons.edit,
              label: 'Umbenennen',
              onPressed: _renameDocument,
            ),
            const SizedBox(height: 12),
            _MenuAction(
              icon: Icons.share,
              label: 'Teilen',
              onPressed: _sharePdf,
            ),
            const SizedBox(height: 12),
            _MenuAction(
              icon: Icons.text_fields,
              label: 'OCR Editor',
              onPressed: _editOcrText,
            ),
            const SizedBox(height: 12),
            _MenuAction(
              icon: Icons.print,
              label: 'Drucken',
              onPressed: _printPdf,
            ),
            const SizedBox(height: 12),
            _MenuAction(
              icon: Icons.description,
              label: 'Volltext anzeigen',
              onPressed: _showOcrTextSheet,
            ),
            const SizedBox(height: 16),
          ],
          FloatingActionButton(
            onPressed: () => setState(() => _isMenuOpen = !_isMenuOpen),
            child: Icon(_isMenuOpen ? Icons.close : Icons.menu),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_document.imagePaths.isEmpty) {
      return const Center(child: Text('No pages available.'));
    }

    final hasMultiplePages = _document.imagePaths.length > 1;

    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          // Disable swiping entirely, navigation is now via FABs
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _document.imagePaths.length,
          onPageChanged: (index) {
            setState(() => _currentPage = index);
          },
          itemBuilder: (context, index) {
            final imagePath = _document.imagePaths[index];
            final pageBlocks = _document.textBlocks != null &&
                    _document.textBlocks!.length > index
                ? _document.textBlocks![index]
                : <OcrTextBlock>[];

            return SelectionArea(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 10.0,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: FutureBuilder<Size>(
                        future: _getImageSize(imagePath, index),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          final imageSize = snapshot.data!;
                          return AspectRatio(
                            aspectRatio: imageSize.width / imageSize.height,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final fittedW = constraints.maxWidth;
                                final pixelToScreen = fittedW / imageSize.width;

                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (imagePath.isNotEmpty)
                                      Positioned.fill(
                                        child: Image.file(
                                          File(imagePath),
                                          width: constraints.maxWidth,
                                          height: constraints.maxHeight,
                                          fit: BoxFit.contain,
                                          alignment: Alignment.center,
                                          errorBuilder: (_, __, ___) =>
                                              const Center(
                                            child: Icon(Icons.broken_image,
                                                size: 64),
                                          ),
                                        ),
                                      )
                                    else if (_pdfDocument != null)
                                      Positioned.fill(
                                        child: PdfLazyImage(
                                          pdfDocument: _pdfDocument!,
                                          pageIndex: index,
                                          fit: BoxFit.contain,
                                        ),
                                      )
                                    else
                                      const Center(
                                          child: CircularProgressIndicator()),
                                    // Invisible but selectable OCR overlay + Search Highlighting
                                    for (int b = 0; b < pageBlocks.length; b++)
                                      for (int l = 0;
                                          l < pageBlocks[b].lines.length;
                                          l++)
                                        for (int e = 0;
                                            e <
                                                pageBlocks[b]
                                                    .lines[l]
                                                    .elements
                                                    .length;
                                            e++)
                                          Builder(
                                            builder: (context) {
                                              final element = pageBlocks[b]
                                                  .lines[l]
                                                  .elements[e];
                                              final isMatch = _searchQuery
                                                      .isNotEmpty &&
                                                  element.text
                                                      .toLowerCase()
                                                      .contains(_searchQuery);
                                              final isCurrentMatch = isMatch &&
                                                  _currentResultIndex >= 0 &&
                                                  _searchResults[
                                                              _currentResultIndex]
                                                          .pageIdx ==
                                                      index &&
                                                  _searchResults[
                                                              _currentResultIndex]
                                                          .blockIdx ==
                                                      b &&
                                                  _searchResults[
                                                              _currentResultIndex]
                                                          .lineIdx ==
                                                      l &&
                                                  _searchResults[
                                                              _currentResultIndex]
                                                          .elemIdx ==
                                                      e;

                                              return Positioned(
                                                left: element.left *
                                                    pixelToScreen,
                                                top:
                                                    element.top * pixelToScreen,
                                                width: element.width *
                                                    pixelToScreen,
                                                height: element.height *
                                                    pixelToScreen,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: isCurrentMatch
                                                        ? Colors.orange
                                                            .withValues(
                                                                alpha: 0.6)
                                                        : (isMatch
                                                            ? Colors.yellow
                                                                .withValues(
                                                                    alpha: 0.4)
                                                            : null),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            2),
                                                  ),
                                                  child: Text(
                                                    '${element.text} ',
                                                    style: TextStyle(
                                                      fontSize: element.height *
                                                          pixelToScreen *
                                                          0.8,
                                                      color: Colors.blue
                                                          .withValues(
                                                              alpha: 0.05),
                                                      backgroundColor:
                                                          Colors.transparent,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                  ],
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),

        // Navigation Buttons (Centered at the bottom)
        if (hasMultiplePages)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // First Page
                  FloatingActionButton.small(
                    heroTag: 'first_page',
                    onPressed: _currentPage > 0 ? _firstPage : null,
                    backgroundColor: _currentPage > 0
                        ? null
                        : Colors.grey.withValues(alpha: 0.5),
                    child: const Icon(Icons.first_page),
                  ),
                  const SizedBox(width: 8),
                  // Prev Page
                  FloatingActionButton.small(
                    heroTag: 'prev_page',
                    onPressed: _currentPage > 0 ? _previousPage : null,
                    backgroundColor: _currentPage > 0
                        ? null
                        : Colors.grey.withValues(alpha: 0.5),
                    child: const Icon(Icons.chevron_left),
                  ),
                  const SizedBox(width: 8),

                  // Page Label (Clickable to jump)
                  GestureDetector(
                    onTap: _showJumpToPageDialog,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24, width: 1),
                      ),
                      child: Text(
                        'Seite ${_currentPage + 1} / ${_document.imagePaths.length}',
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
                    onPressed: _currentPage < _document.imagePaths.length - 1
                        ? _nextPage
                        : null,
                    backgroundColor:
                        _currentPage < _document.imagePaths.length - 1
                            ? null
                            : Colors.grey.withValues(alpha: 0.5),
                    child: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: 8),
                  // Last Page
                  FloatingActionButton.small(
                    heroTag: 'last_page',
                    onPressed: _currentPage < _document.imagePaths.length - 1
                        ? _lastPage
                        : null,
                    backgroundColor:
                        _currentPage < _document.imagePaths.length - 1
                            ? null
                            : Colors.grey.withValues(alpha: 0.5),
                    child: const Icon(Icons.last_page),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTextView() {
    // This is no longer used directly as a tab but kept for reference if needed
    return Container();
  }
}

class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FloatingActionButton.small(
          heroTag: 'menu_$label',
          onPressed: onPressed,
          child: Icon(icon),
        ),
      ],
    );
  }
}

/// Dialog for renaming a document.
///
/// Owns the [TextEditingController] so that it is disposed via [State.dispose]
/// after the dialog widget is fully removed from the tree — preventing the
/// `_dependents.isEmpty` assertion that can fire when the controller is
/// disposed while the closing animation is still in progress.
class _RenameDocumentDialog extends StatefulWidget {
  final String initialTitle;

  const _RenameDocumentDialog({required this.initialTitle});

  @override
  State<_RenameDocumentDialog> createState() => _RenameDocumentDialogState();
}

class _RenameDocumentDialogState extends State<_RenameDocumentDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename Document'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Document name',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
