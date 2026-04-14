import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_document.dart';
import '../services/storage_service.dart';
import '../utils/filename_utils.dart';
import 'ocr_edit_screen.dart';

/// Screen for viewing the details of a scanned document.
///
/// Displays page images with an optional OCR text overlay and provides
/// options to rename, share or print the generated PDF.
class ScanResultScreen extends StatefulWidget {
  final ScanDocument document;

  const ScanResultScreen({super.key, required this.document});

  @override
  State<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends State<ScanResultScreen> {
  static const _pageBreakDelimiter = '\n\n--- Page Break ---\n\n';
  static const _overlayOpacity = 0.75;

  final StorageService _storageService = StorageService();
  late ScanDocument _document;
  bool _showOcrOverlay = false;
  int _currentPage = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _document = widget.document;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _renameDocument() async {
    if (!mounted) return;

    final newTitle = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDocumentDialog(initialTitle: _document.title),
    );

    if (!mounted) return;

    if (newTitle != null && newTitle.isNotEmpty && newTitle != _document.title) {
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
    final updated = await Navigator.of(context).push<ScanDocument>(
      MaterialPageRoute(
        builder: (_) => OcrEditScreen(document: _document),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _document = updated);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  /// Splits the combined OCR text into per-page strings.
  List<String> get _ocrPages =>
      _document.ocrText.split(_pageBreakDelimiter);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_document.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Rename',
            onPressed: _renameDocument,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share PDF',
            onPressed: _sharePdf,
          ),
          // OCR toggle – shown next to the Print button
          IconButton(
            icon: Icon(
              Icons.text_fields,
              color: _showOcrOverlay ? colorScheme.primary : null,
            ),
            tooltip: 'Toggle OCR Text',
            onPressed: () =>
                setState(() => _showOcrOverlay = !_showOcrOverlay),
          ),
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Print',
            onPressed: _printPdf,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_document.imagePaths.isEmpty) {
      return const Center(child: Text('No pages available.'));
    }

    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          itemCount: _document.imagePaths.length,
          onPageChanged: (index) => setState(() => _currentPage = index),
          itemBuilder: (context, index) {
            final imagePath = _document.imagePaths[index];
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(imagePath),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.broken_image, size: 64),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Page ${index + 1} of ${_document.pageCount}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        if (_showOcrOverlay) _buildOcrOverlay(),
      ],
    );
  }

  /// Semi-transparent panel anchored to the bottom of the screen that
  /// shows the OCR text for the currently visible page and lets the
  /// user edit it.
  Widget _buildOcrOverlay() {
    final pages = _ocrPages;
    final pageText =
        _currentPage < pages.length ? pages[_currentPage].trim() : '';

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.35,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(_overlayOpacity),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header row with title and edit button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'OCR Text',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.edit,
                      color: Colors.white70,
                      size: 20,
                    ),
                    tooltip: 'Edit OCR text',
                    onPressed: _editOcrText,
                  ),
                ],
              ),
            ),
            // Per-page OCR text content
            if (pageText.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text(
                  'No text recognized on this page.',
                  style: TextStyle(color: Colors.white60),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text(
                    pageText,
                    style: const TextStyle(color: Colors.white, height: 1.4),
                  ),
                ),
              ),
          ],
        ),
      ),
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
