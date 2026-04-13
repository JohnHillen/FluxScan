import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/scan_document.dart';

/// Service responsible for persisting scanned documents to local storage.
///
/// Documents are stored as JSON in [SharedPreferences] for metadata,
/// while image and PDF files are stored in the app's documents directory.
class StorageService {
  static const _documentsKey = 'fluxscan_documents';

  /// Saves a [ScanDocument] to local storage.
  ///
  /// If a document with the same [ScanDocument.id] already exists,
  /// it will be replaced.
  Future<void> saveDocument(ScanDocument document) async {
    final documents = await getDocuments();
    final index = documents.indexWhere((d) => d.id == document.id);

    if (index >= 0) {
      documents[index] = document;
    } else {
      documents.insert(0, document);
    }

    await _persistDocuments(documents);
  }

  /// Retrieves all stored documents, sorted by most recent first.
  Future<List<ScanDocument>> getDocuments() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_documentsKey);

    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final jsonList = jsonDecode(jsonString) as List;
      final documents = jsonList
          .map((e) => ScanDocument.fromJson(e as Map<String, dynamic>))
          .toList();

      // Sort by most recent first
      documents.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return documents;
    } catch (e) {
      // If data is corrupted, return empty list
      return [];
    }
  }

  /// Deletes a document and its associated files from storage.
  Future<void> deleteDocument(String documentId) async {
    final documents = await getDocuments();
    final document = documents.where((d) => d.id == documentId).firstOrNull;

    if (document != null) {
      // Delete associated image files
      for (final path in document.imagePaths) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Delete the PDF file if it exists
      if (document.pdfPath != null) {
        final pdfFile = File(document.pdfPath!);
        if (await pdfFile.exists()) {
          await pdfFile.delete();
        }
      }
    }

    // Remove from the stored list
    documents.removeWhere((d) => d.id == documentId);
    await _persistDocuments(documents);
  }

  /// Returns the path to the app's document storage directory.
  Future<String> getStorageDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final scanDir = Directory('${dir.path}/scans');
    if (!await scanDir.exists()) {
      await scanDir.create(recursive: true);
    }
    return scanDir.path;
  }

  /// Persists the full documents list to SharedPreferences.
  Future<void> _persistDocuments(List<ScanDocument> documents) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(
      documents.map((d) => d.toJson()).toList(),
    );
    await prefs.setString(_documentsKey, jsonString);
  }
}
