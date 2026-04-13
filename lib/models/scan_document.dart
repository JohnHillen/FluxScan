import 'dart:convert';

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

  /// Timestamp when the document was first scanned.
  final DateTime createdAt;

  /// Timestamp of the last modification.
  final DateTime updatedAt;

  /// Number of pages in this document.
  int get pageCount => imagePaths.length;

  const ScanDocument({
    required this.id,
    required this.title,
    required this.imagePaths,
    this.ocrText = '',
    this.pdfPath,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates a copy of this document with the given fields replaced.
  ScanDocument copyWith({
    String? id,
    String? title,
    List<String>? imagePaths,
    String? ocrText,
    String? pdfPath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ScanDocument(
      id: id ?? this.id,
      title: title ?? this.title,
      imagePaths: imagePaths ?? this.imagePaths,
      ocrText: ocrText ?? this.ocrText,
      pdfPath: pdfPath ?? this.pdfPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
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
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Deserializes a [ScanDocument] from a JSON map.
  factory ScanDocument.fromJson(Map<String, dynamic> json) {
    return ScanDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      imagePaths: List<String>.from(json['imagePaths'] as List),
      ocrText: json['ocrText'] as String? ?? '',
      pdfPath: json['pdfPath'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
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
