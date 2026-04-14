import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/scan_document.dart';
import '../services/document_naming_service.dart';
import '../services/pdf_service.dart';
import '../services/scanner_service.dart';
import '../services/storage_service.dart';
import '../utils/filename_utils.dart';
import '../widgets/scan_card.dart';
import 'scan_result_screen.dart';
import 'settings_screen.dart';

/// The main screen displaying a list of recent scans with a FAB to start new scans.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final StorageService _storageService = StorageService();
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  final DocumentNamingService _namingService = DocumentNamingService();

  List<ScanDocument> _documents = [];
  bool _isLoading = true;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  @override
  void dispose() {
    _scannerService.dispose();
    super.dispose();
  }

  Future<void> _loadDocuments() async {
    setState(() => _isLoading = true);
    try {
      final documents = await _storageService.getDocuments();
      if (mounted) {
        setState(() {
          _documents = documents;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showError('Failed to load documents: $e');
      }
    }
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    setState(() => _isScanning = true);

    try {
      // Step 1: Open native document scanner
      final imagePaths = await _scannerService.scanDocument();
      if (imagePaths.isEmpty) {
        if (mounted) setState(() => _isScanning = false);
        return;
      }

      if (!mounted) return;

      // Show processing indicator
      _showSnackBar('Processing scan...');

      // Step 2: Enhance images and run OCR
      final processed = await _scannerService.processImages(imagePaths);

      // Step 3: Generate searchable PDF (use original images for the visual layer)
      final firstPageBlocks =
          processed.textBlocks.isNotEmpty ? processed.textBlocks[0] : [];
      final title = _namingService.generateName(firstPageBlocks);

      final pdfPath = await _pdfService.generateSearchablePdf(
        imagePaths: processed.originalImagePaths,
        textBlocks: processed.textBlocks,
        title: title,
      );

      // Step 4: Save the document (use original images for display)
      final document = ScanDocument(
        id: const Uuid().v4(),
        title: title,
        imagePaths: processed.originalImagePaths,
        ocrText: processed.combinedText,
        pdfPath: pdfPath,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        textBlocks: processed.textBlocks,
      );

      await _storageService.saveDocument(document);
      await _loadDocuments();

      if (mounted) {
        setState(() => _isScanning = false);
        _showSnackBar('Scan completed successfully!');

        // Navigate to the result screen
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ScanResultScreen(document: document),
          ),
        );
        // Reload in case the document was modified
        await _loadDocuments();
      }
    } on ScannerException catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        _showError(e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        _showError('An unexpected error occurred: $e');
      }
    }
  }

  Future<void> _deleteDocument(ScanDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Scan'),
        content: Text('Are you sure you want to delete "${document.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _storageService.deleteDocument(document.id);
      await _loadDocuments();
      if (mounted) {
        _showSnackBar('Scan deleted.');
      }
    }
  }

  Future<void> _shareDocument(ScanDocument document) async {
    if (document.pdfPath == null) {
      _showError('No PDF available to share.');
      return;
    }

    final file = File(document.pdfPath!);
    if (!await file.exists()) {
      _showError('PDF file not found.');
      return;
    }

    // Copy to temp directory with the correct document title as filename so
    // the recipient sees a meaningful name instead of the UUID-based path.
    final fileName = sanitizedPdfFilename(document.title);
    final tempDir = await getTemporaryDirectory();
    final tempFile = await File(document.pdfPath!).copy(
      '${tempDir.path}/$fileName',
    );

    await Share.shareXFiles(
      [XFile(tempFile.path)],
      subject: document.title,
    );
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

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FluxScan'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        icon: _isScanning
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.document_scanner),
        label: Text(_isScanning ? 'Scanning...' : 'Scan'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_documents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.document_scanner_outlined,
                size: 80,
                color: Theme.of(context).colorScheme.primary.withAlpha(128),
              ),
              const SizedBox(height: 16),
              Text(
                'No scans yet',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Tap the scan button to get started.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withAlpha(153),
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDocuments,
      child: ListView.builder(
        padding: const EdgeInsets.only(
          top: 8,
          bottom: 88, // Space for FAB
        ),
        itemCount: _documents.length,
        itemBuilder: (context, index) {
          final document = _documents[index];
          return ScanCard(
            document: document,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ScanResultScreen(document: document),
                ),
              );
              await _loadDocuments();
            },
            onShare: () => _shareDocument(document),
            onDelete: () => _deleteDocument(document),
          );
        },
      ),
    );
  }
}
