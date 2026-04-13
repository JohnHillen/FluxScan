import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_document.dart';

/// Screen for viewing the details of a scanned document.
///
/// Displays page images, extracted OCR text, and provides options
/// to share or print the generated PDF.
class ScanResultScreen extends StatefulWidget {
  final ScanDocument document;

  const ScanResultScreen({super.key, required this.document});

  @override
  State<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends State<ScanResultScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _sharePdf() async {
    if (widget.document.pdfPath == null) {
      _showError('No PDF available.');
      return;
    }

    final file = File(widget.document.pdfPath!);
    if (!await file.exists()) {
      _showError('PDF file not found.');
      return;
    }

    await Share.shareXFiles(
      [XFile(widget.document.pdfPath!)],
      subject: widget.document.title,
    );
  }

  Future<void> _printPdf() async {
    if (widget.document.pdfPath == null) {
      _showError('No PDF available.');
      return;
    }

    final file = File(widget.document.pdfPath!);
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
        title: Text(widget.document.title),
        actions: [
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
    if (widget.document.imagePaths.isEmpty) {
      return const Center(child: Text('No pages available.'));
    }

    return PageView.builder(
      itemCount: widget.document.imagePaths.length,
      itemBuilder: (context, index) {
        final imagePath = widget.document.imagePaths[index];
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
                    'Page ${index + 1} of ${widget.document.pageCount}',
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
    if (widget.document.ocrText.isEmpty) {
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
        widget.document.ocrText,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontFamily: 'monospace',
              height: 1.5,
            ),
      ),
    );
  }
}
