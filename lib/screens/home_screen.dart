import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/scan_document.dart';
import '../services/document_naming_service.dart';
import '../services/pdf_import_service.dart';
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
  static const _uuid = Uuid();

  final StorageService _storageService = StorageService();
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  final DocumentNamingService _namingService = DocumentNamingService();
  final PdfImportService _pdfImportService = PdfImportService();

  List<ScanDocument> _documents = [];
  bool _isLoading = true;
  bool _isScanning = false;
  bool _isMenuOpen = false;

  // Multi-Select State
  final Set<String> _selectedIds = {};
  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  /// Notifier used to stream progress (0.0–1.0) into the processing dialog.
  final ValueNotifier<double> _progressNotifier = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  @override
  void dispose() {
    _scannerService.dispose();
    _progressNotifier.dispose();
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

    var progressDialogShown = false;

    try {
      // Step 1: Open native document scanner
      final imagePaths = await _scannerService.scanDocument();
      if (imagePaths.isEmpty) {
        if (mounted) setState(() => _isScanning = false);
        return;
      }

      if (!mounted) return;

      // Step 2: Enhance images and run OCR – show progress dialog.
      _progressNotifier.value = 0.0;
      _showProcessingDialog('Processing…');
      progressDialogShown = true;

      final processed = await _scannerService.processImages(
        imagePaths,
        onProgress: (current, total) {
          _progressNotifier.value = current / total;
        },
      );

      // Close the progress dialog.
      if (mounted) Navigator.of(context).pop();
      progressDialogShown = false;

      // Step 3: Generate searchable PDF (use original images for the visual layer)
      final firstPageBlocks =
          processed.textBlocks.isNotEmpty ? processed.textBlocks[0] : <OcrTextBlock>[];
      final title = _namingService.generateName(firstPageBlocks);

      final pdfPath = await _pdfService.generateSearchablePdf(
        imagePaths: processed.originalImagePaths,
        textBlocks: processed.textBlocks,
        title: title,
      );

      // Step 4: Save the document (use original images for display)
      final document = ScanDocument(
        id: _uuid.v4(),
        title: title,
        imagePaths: processed.originalImagePaths,
        ocrText: processed.combinedText,
        pdfPath: pdfPath,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        textBlocks: processed.textBlocks,
        imageSizes: processed.imageSizes,
      );

      await _storageService.saveDocument(document);
      await _loadDocuments();

      if (mounted) {
        setState(() => _isScanning = false);
        // _showSnackBar('Scan completed successfully!');

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
        if (progressDialogShown) Navigator.of(context).pop();
        setState(() => _isScanning = false);
        _showError(e.message);
      }
    } catch (e) {
      if (mounted) {
        if (progressDialogShown) Navigator.of(context).pop();
        setState(() => _isScanning = false);
        _showError('An unexpected error occurred: $e');
      }
    }
  }

  Future<void> _importPdf() async {
    if (_isScanning) return;

    setState(() => _isScanning = true);

    // Track temp image paths so they can always be cleaned up.
    var tempImagePaths = <String>[];
    var progressDialogShown = false;

    try {
      // Step 1: Let the user pick a PDF file.
      final pdfPath = await _pdfImportService.pickPdfFile();
      if (pdfPath == null) {
        if (mounted) setState(() => _isScanning = false);
        return;
      }

      if (!mounted) return;

      // Step 2: Check if the PDF already contains text.
      final checkResult = await _pdfImportService.openAndCheckText(pdfPath);
      final hasDigitalText = checkResult.hasText;
      final pdfDocument = checkResult.document;
      bool useDigitalText = false;

      if (hasDigitalText && mounted) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Text erkannt'),
            content: const Text(
              'Dieses PDF enthält bereits Text. Möchtest du den vorhandenen Text verwenden (schneller & präziser) oder eine neue Texterkennung (OCR) durchführen?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop('ocr'),
                child: const Text('Neu scannen (OCR)'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('digital'),
                child: const Text('Text übernehmen'),
              ),
            ],
          ),
        );
        if (choice == null) {
          await pdfDocument.dispose();
          setState(() => _isScanning = false);
          return;
        }
        useDigitalText = choice == 'digital';
      }

      if (!mounted) return;

      // Step 3: Process PDF (Render images & optionally extract text).
      _progressNotifier.value = 0.0;
      _showProcessingDialog('Importing PDF…');
      progressDialogShown = true;

      PdfImportResult importResult;
      if (useDigitalText) {
        // FAST PATH: Just extract text and dimensions, no rendering!
        importResult = await _pdfImportService.extractMetadata(pdfPath);
        
        // BUT: We need a thumbnail! Render the first page.
        final thumbPath = await _pdfImportService.renderPage(pdfPath, 0);
        tempImagePaths = [thumbPath];
      } else {
        // SLOW PATH: Render images for OCR or if digital text is not used.
        importResult = await _pdfImportService.processPdf(
          pdfPath,
          onProgress: (progress) {
            // Rendering is only the first part (0-50%) if using OCR.
            _progressNotifier.value = progress * 0.5;
          },
        );
        tempImagePaths = importResult.imagePaths;
      }
      
      if (!useDigitalText && tempImagePaths.isEmpty) {
        if (mounted) {
          if (progressDialogShown) Navigator.of(context).pop();
          setState(() => _isScanning = false);
          _showError('No pages could be rendered from the PDF.');
        }
        return;
      }

      // Step 4: Extract text (either via digital extraction or OCR).
      ProcessedScan processed;
      if (useDigitalText) {
        final textBlocks = importResult.textBlocks!;
        processed = ProcessedScan(
          originalImagePaths: tempImagePaths, // Use the thumbnail path
          enhancedImagePaths: [],
          textBlocks: textBlocks,
          imageSizes: importResult.imageSizes,
          combinedText: textBlocks.expand((p) => p).map((b) => b.text).join('\n\n'),
        );
      } else {
        processed = await _scannerService.processImages(
          tempImagePaths,
          onProgress: (current, total) {
            _progressNotifier.value = 0.5 + (current / total) * 0.5;
          },
        );
      }

      // Step 5: Copy images to persistent storage.
      final docsDir = await getApplicationDocumentsDirectory();
      final persistentImagePaths = <String>[];
      
      if (useDigitalText) {
        // Copy the thumbnail
        final tmpPath = processed.originalImagePaths[0];
        final persistentPath = '${docsDir.path}/imported_${_uuid.v4()}.png';
        await File(tmpPath).copy(persistentPath);
        persistentImagePaths.add(persistentPath);
        
        // For lazy rendering, we use empty strings for the remaining pages.
        for (var i = 1; i < importResult.pageDimensions.length; i++) {
          persistentImagePaths.add('');
        }
      } else {
        for (final tmpPath in processed.originalImagePaths) {
          final persistentPath = '${docsDir.path}/imported_${_uuid.v4()}.png';
          await File(tmpPath).copy(persistentPath);
          persistentImagePaths.add(persistentPath);
        }
      }

      // Step 6: Get the searchable PDF.
      // OPTIMIZATION: If we used digital text, we already have the original PDF!
      // No need to re-generate it from images (which is very slow for large files).
      String finalPdfPath;
      final fileName = pdfPath.split(Platform.pathSeparator).last;
      final title = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');

      if (useDigitalText) {
        finalPdfPath = '${docsDir.path}/${_uuid.v4()}.pdf';
        await File(pdfPath).copy(finalPdfPath);
      } else {
        finalPdfPath = await _pdfService.generateSearchablePdf(
          imagePaths: persistentImagePaths,
          textBlocks: processed.textBlocks,
          title: title,
          pageDimensions: importResult.pageDimensions,
        );
      }

      // Step 7: Save the document with the persistent image paths.
      final document = ScanDocument(
        id: _uuid.v4(),
        title: title,
        imagePaths: persistentImagePaths,
        ocrText: processed.combinedText,
        pdfPath: finalPdfPath,
        sourcePdfPath: useDigitalText ? finalPdfPath : null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        textBlocks: processed.textBlocks,
        imageSizes: processed.imageSizes,
      );

      await _storageService.saveDocument(document);
      await _loadDocuments();

      // Close the progress dialog now that everything is persisted.
      if (mounted && progressDialogShown) {
        Navigator.of(context).pop();
        progressDialogShown = false;
      }

      // Step 8: Delete the temporary rendered images now that the searchable
      // PDF has been generated and the document is saved.
      for (final path in tempImagePaths) {
        try {
          await File(path).delete();
        } catch (_) {
          // Best-effort cleanup; ignore individual file errors.
        }
      }
      tempImagePaths = [];

      if (mounted) {
        setState(() => _isScanning = false);
        // _showSnackBar('PDF erfolgreich importiert!');

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ScanResultScreen(document: document),
          ),
        );
        await _loadDocuments();
      }
    } catch (e) {
      // Clean up any temporary images that were created before the error.
      for (final path in tempImagePaths) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      if (mounted) {
        if (progressDialogShown) Navigator.of(context).pop();
        setState(() => _isScanning = false);
        _showError('Failed to import PDF: $e');
      }
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectedIds.clear();
      _isMenuOpen = false;
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Scans löschen'),
        content: Text('Möchtest du wirklich $count ausgewählte Scans löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Alle löschen'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      for (final id in _selectedIds) {
        await _storageService.deleteDocument(id);
      }
      _exitSelectionMode();
      await _loadDocuments();
      // _showSnackBar('$count Scans gelöscht.');
    }
  }

  Future<void> _shareSelected() async {
    final selectedDocs = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    final filesToShare = <XFile>[];

    for (final doc in selectedDocs) {
      if (doc.pdfPath != null) {
        final file = File(doc.pdfPath!);
        if (await file.exists()) {
          // Copy to temp with title
          final fileName = sanitizedPdfFilename(doc.title);
          final tempDir = await getTemporaryDirectory();
          final tempFile = await File(doc.pdfPath!).copy('${tempDir.path}/$fileName');
          filesToShare.add(XFile(tempFile.path));
        }
      }
    }

    if (filesToShare.isNotEmpty) {
      await Share.shareXFiles(filesToShare, subject: 'FluxScan Export');
      _exitSelectionMode();
    } else {
      _showError('Keine PDFs zum Teilen gefunden.');
    }
  }

  Future<void> _deleteDocument(ScanDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Löschen'),
        content: Text('"${document.title}" wirklich löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _storageService.deleteDocument(document.id);
      await _loadDocuments();
      if (mounted) {
        // _showSnackBar('Scan gelöscht.');
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

  /// Shows a non-dismissible progress dialog that displays a percentage.
  ///
  /// The dialog listens to [_progressNotifier] and updates automatically.
  /// Call [Navigator.of(context).pop()] to close it when processing finishes.
  void _showProcessingDialog(String title) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<double>(
            valueListenable: _progressNotifier,
            builder: (_, progress, __) {
              final percent = (progress * 100).round();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 12),
                  Text(
                    '$percent %',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _showError(String message) {
    debugPrint('Error: $message');
    // Disabled as per user request to not block the FAB
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

  void _showSnackBar(String message) {
    // Disabled as per user request to not block the FAB
    // if (!mounted) return;
    // ScaffoldMessenger.of(context).showSnackBar(
    //   SnackBar(content: Text(message)),
    // );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : null,
        title: _isSelectionMode 
            ? Text('${_selectedIds.length} ausgewählt') 
            : const Text('FluxScan'),
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Ausgewählte teilen',
              onPressed: _shareSelected,
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              tooltip: 'Ausgewählte löschen',
              onPressed: _deleteSelected,
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Einstellungen',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          ],
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
          if (!_isSelectionMode) _buildActionMenu(),
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
              icon: Icons.document_scanner,
              label: 'Kamera Scan',
              onPressed: () {
                setState(() => _isMenuOpen = false);
                _startScan();
              },
            ),
            const SizedBox(height: 12),
            _MenuAction(
              icon: Icons.picture_as_pdf,
              label: 'PDF Import',
              onPressed: () {
                setState(() => _isMenuOpen = false);
                _importPdf();
              },
            ),
            const SizedBox(height: 16),
          ],
          FloatingActionButton(
            heroTag: 'home_menu',
            onPressed: _isScanning ? null : () => setState(() => _isMenuOpen = !_isMenuOpen),
            child: _isScanning
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(_isMenuOpen ? Icons.close : Icons.menu),
          ),
        ],
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
          final isSelected = _selectedIds.contains(document.id);
          return ScanCard(
            document: document,
            isSelected: isSelected,
            isSelectionMode: _isSelectionMode,
            onTap: () async {
              if (_isSelectionMode) {
                _toggleSelection(document.id);
              } else {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ScanResultScreen(document: document),
                  ),
                );
                await _loadDocuments();
              }
            },
            onLongPress: () {
              if (!_isSelectionMode) {
                _toggleSelection(document.id);
              }
            },
            onShare: () => _shareDocument(document),
            onDelete: () => _deleteDocument(document),
          );
        },
      ),
    );
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
          heroTag: 'home_menu_$label',
          onPressed: onPressed,
          child: Icon(icon),
        ),
      ],
    );
  }
}
