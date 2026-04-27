import 'dart:ui';
import 'dart:convert';

import '../services/scanner_service.dart';

/// Represents a scanned document with its metadata and file paths.
///
/// Each [ScanDocument] corresponds to a single scanning session that may
/// contain one or more page images, extracted OCR text, and a generated PDF.
class ScanDocument {
  /// Unique identifier for the document.
  final String id;

  /// User-visible title for the scan.
  final String title;

  /// File paths to the scanned page images (in order).
  final List<String> imagePaths;

  /// Extracted OCR text from all pages combined.
  final String ocrText;

  /// File path to the generated searchable PDF, if available.
  final String? pdfPath;
  
  /// File path to the original PDF for lazy rendering.
  final String? sourcePdfPath;

  /// Timestamp when the document was first scanned.
  final DateTime createdAt;

  /// Timestamp of the last modification.
  final DateTime updatedAt;

  /// Structured OCR text blocks per page, used for word-level PDF overlay.
  ///
  /// Each entry corresponds to one page and contains [OcrTextBlock] objects
  /// with bounding box positions and nested [OcrTextLine]/[OcrTextElement]
  /// data. `null` for documents created before word-level OCR was stored.
  final List<List<OcrTextBlock>>? textBlocks;
  
  /// The resolved pixel dimensions of each page.
  /// 
  /// For imported PDFs, these are the dimensions of the page at the render scale (3.0x).
  /// For physical scans, these are the dimensions of the processed images.
  final List<Size?>? imageSizes;

  /// Number of pages in this document.
  int get pageCount => imagePaths.length;

  const ScanDocument({
    required this.id,
    required this.title,
    required this.imagePaths,
    this.ocrText = '',
    this.pdfPath,
    this.sourcePdfPath,
    required this.createdAt,
    required this.updatedAt,
    this.textBlocks,
    this.imageSizes,
  });

  /// Creates a copy of this document with the given fields replaced.
  ScanDocument copyWith({
    String? id,
    String? title,
    List<String>? imagePaths,
    String? ocrText,
    String? pdfPath,
    String? sourcePdfPath,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<List<OcrTextBlock>>? textBlocks,
    List<Size?>? imageSizes,
  }) {
    return ScanDocument(
      id: id ?? this.id,
      title: title ?? this.title,
      imagePaths: imagePaths ?? this.imagePaths,
      ocrText: ocrText ?? this.ocrText,
      pdfPath: pdfPath ?? this.pdfPath,
      sourcePdfPath: sourcePdfPath ?? this.sourcePdfPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      textBlocks: textBlocks ?? this.textBlocks,
      imageSizes: imageSizes ?? this.imageSizes,
    );
  }

  /// Serializes this document to a JSON map for local storage.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'imagePaths': imagePaths,
      'ocrText': ocrText,
      'pdfPath': pdfPath,
      'sourcePdfPath': sourcePdfPath,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (textBlocks != null)
        'textBlocks': textBlocks!
            .map((page) => page.map((b) => b.toJson()).toList())
            .toList(),
      if (imageSizes != null)
        'imageSizes': imageSizes!
            .map((s) => s != null ? {'w': s.width, 'h': s.height} : null)
            .toList(),
    };
  }

  /// Deserializes a [ScanDocument] from a JSON map.
  factory ScanDocument.fromJson(Map<String, dynamic> json) {
    List<List<OcrTextBlock>>? textBlocks;
    if (json['textBlocks'] != null) {
      textBlocks = (json['textBlocks'] as List<dynamic>)
          .map(
            (page) => (page as List<dynamic>)
                .map(
                  (b) => OcrTextBlock.fromJson(b as Map<String, dynamic>),
                )
                .toList(),
          )
          .toList();
    }

    List<Size?>? imageSizes;
    if (json['imageSizes'] != null) {
      imageSizes = (json['imageSizes'] as List<dynamic>)
          .map((s) => s != null ? Size((s['w'] as num).toDouble(), (s['h'] as num).toDouble()) : null)
          .toList();
    }

    return ScanDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      imagePaths: List<String>.from(json['imagePaths'] as List),
      ocrText: json['ocrText'] as String? ?? '',
      pdfPath: json['pdfPath'] as String?,
      sourcePdfPath: json['sourcePdfPath'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      textBlocks: textBlocks,
      imageSizes: imageSizes,
    );
  }

  /// Encodes this document as a JSON string.
  String toJsonString() => jsonEncode(toJson());

  /// Decodes a [ScanDocument] from a JSON string.
  factory ScanDocument.fromJsonString(String source) {
    return ScanDocument.fromJson(
      jsonDecode(source) as Map<String, dynamic>,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScanDocument && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'ScanDocument(id: $id, title: $title, pages: $pageCount)';
  }
}
