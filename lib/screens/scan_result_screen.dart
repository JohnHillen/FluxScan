import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_document.dart';
import '../services/storage_service.dart';
import '../utils/filename_utils.dart';

/// Screen for viewing the details of a scanned document.
///
/// Displays page images, extracted OCR text, and provides options
/// to rename, share or print the generated PDF.
class ScanResultScreen extends StatefulWidget {
  final ScanDocument document;

  const ScanResultScreen({super.key, required this.document});

  @override
  State<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends State<ScanResultScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final StorageService _storageService = StorageService();
  late ScanDocument _document;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _document = widget.document;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _renameDocument() async {
    final controller = TextEditingController(text: _document.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Document'),
        content: TextField(
          controller: controller,
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
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

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

    // Use the document title as the shared filename so the recipient
    // sees a meaningful name instead of the internal UUID-based path.
    final fileName = sanitizedPdfFilename(_document.title);

    await Share.shareXFiles(
      [XFile(_document.pdfPath!, name: fileName)],
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

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Print',
            onPressed: _printPdf,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.image), text: 'Pages'),
            Tab(icon: Icon(Icons.text_snippet), text: 'Text'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildPagesView(),
          _buildTextView(),
        ],
      ),
    );
  }

  Widget _buildPagesView() {
    if (_document.imagePaths.isEmpty) {
      return const Center(child: Text('No pages available.'));
    }

    return PageView.builder(
      itemCount: _document.imagePaths.length,
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
    );
  }

  Widget _buildTextView() {
    if (_document.ocrText.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.text_snippet_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withAlpha(128),
            ),
            const SizedBox(height: 16),
            const Text('No text was recognized.'),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        _document.ocrText,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontFamily: 'monospace',
              height: 1.5,
            ),
      ),
    );
  }
}
