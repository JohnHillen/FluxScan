import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxscan/models/scan_document.dart';
import 'package:fluxscan/services/scanner_service.dart';

void main() {
  group('ScanDocument', () {
    final testDate = DateTime(2024, 1, 15, 10, 30);

    /// Helper text blocks used across multiple tests.
    const testTextBlocks = [
      [
        OcrTextBlock(
          text: 'Hello World',
          left: 10.0,
          top: 20.0,
          width: 200.0,
          height: 30.0,
          lines: [
            OcrTextLine(
              text: 'Hello World',
              elements: [
                OcrTextElement(
                  text: 'Hello',
                  left: 10.0,
                  top: 20.0,
                  width: 90.0,
                  height: 20.0,
                ),
                OcrTextElement(
                  text: 'World',
                  left: 105.0,
                  top: 20.0,
                  width: 95.0,
                  height: 20.0,
                ),
              ],
            ),
          ],
        ),
      ],
    ];

    ScanDocument createTestDocument({
      String id = 'test-id-123',
      String title = 'Test Scan',
      List<String> imagePaths = const ['/path/to/image1.png'],
      String ocrText = 'Recognized text content',
      String? pdfPath = '/path/to/scan.pdf',
      DateTime? createdAt,
      DateTime? updatedAt,
      List<List<OcrTextBlock>>? textBlocks,
    }) {
      return ScanDocument(
        id: id,
        title: title,
        imagePaths: imagePaths,
        ocrText: ocrText,
        pdfPath: pdfPath,
        createdAt: createdAt ?? testDate,
        updatedAt: updatedAt ?? testDate,
        textBlocks: textBlocks,
      );
    }

    test('should create a document with all fields', () {
      final doc = createTestDocument();

      expect(doc.id, 'test-id-123');
      expect(doc.title, 'Test Scan');
      expect(doc.imagePaths, ['/path/to/image1.png']);
      expect(doc.ocrText, 'Recognized text content');
      expect(doc.pdfPath, '/path/to/scan.pdf');
      expect(doc.createdAt, testDate);
      expect(doc.updatedAt, testDate);
      expect(doc.textBlocks, isNull);
    });

    test('should store textBlocks when provided', () {
      final doc = createTestDocument(textBlocks: testTextBlocks);
      expect(doc.textBlocks, isNotNull);
      expect(doc.textBlocks!.length, 1);
      expect(doc.textBlocks![0][0].lines[0].elements[0].text, 'Hello');
    });

    test('should calculate page count correctly', () {
      final singlePage = createTestDocument(
        imagePaths: ['/page1.png'],
      );
      expect(singlePage.pageCount, 1);

      final multiPage = createTestDocument(
        imagePaths: ['/page1.png', '/page2.png', '/page3.png'],
      );
      expect(multiPage.pageCount, 3);

      final noPages = createTestDocument(imagePaths: []);
      expect(noPages.pageCount, 0);
    });

    test('should default ocrText to empty string', () {
      final doc = ScanDocument(
        id: 'id',
        title: 'title',
        imagePaths: const [],
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(doc.ocrText, '');
    });

    group('copyWith', () {
      test('should create a copy with updated fields', () {
        final original = createTestDocument();
        final newDate = DateTime(2024, 6, 1);

        final updated = original.copyWith(
          title: 'Updated Title',
          ocrText: 'New OCR text',
          updatedAt: newDate,
        );

        expect(updated.id, original.id);
        expect(updated.title, 'Updated Title');
        expect(updated.ocrText, 'New OCR text');
        expect(updated.updatedAt, newDate);
        // Unchanged fields
        expect(updated.imagePaths, original.imagePaths);
        expect(updated.pdfPath, original.pdfPath);
        expect(updated.createdAt, original.createdAt);
      });

      test('should preserve original values when no arguments given', () {
        final original = createTestDocument();
        final copy = original.copyWith();

        expect(copy.id, original.id);
        expect(copy.title, original.title);
        expect(copy.imagePaths, original.imagePaths);
        expect(copy.ocrText, original.ocrText);
        expect(copy.pdfPath, original.pdfPath);
      });

      test('should update textBlocks via copyWith', () {
        final original = createTestDocument();
        expect(original.textBlocks, isNull);

        final updated = original.copyWith(textBlocks: testTextBlocks);
        expect(updated.textBlocks, isNotNull);
        expect(updated.textBlocks!.length, 1);
        // Other fields unchanged
        expect(updated.id, original.id);
      });
    });

    group('JSON serialization', () {
      test('should serialize to JSON correctly', () {
        final doc = createTestDocument();
        final json = doc.toJson();

        expect(json['id'], 'test-id-123');
        expect(json['title'], 'Test Scan');
        expect(json['imagePaths'], ['/path/to/image1.png']);
        expect(json['ocrText'], 'Recognized text content');
        expect(json['pdfPath'], '/path/to/scan.pdf');
        expect(json['createdAt'], testDate.toIso8601String());
        expect(json['updatedAt'], testDate.toIso8601String());
      });

      test('should deserialize from JSON correctly', () {
        final json = {
          'id': 'test-id-123',
          'title': 'Test Scan',
          'imagePaths': ['/path/to/image1.png'],
          'ocrText': 'Recognized text content',
          'pdfPath': '/path/to/scan.pdf',
          'createdAt': testDate.toIso8601String(),
          'updatedAt': testDate.toIso8601String(),
        };

        final doc = ScanDocument.fromJson(json);

        expect(doc.id, 'test-id-123');
        expect(doc.title, 'Test Scan');
        expect(doc.imagePaths, ['/path/to/image1.png']);
        expect(doc.ocrText, 'Recognized text content');
        expect(doc.pdfPath, '/path/to/scan.pdf');
      });

      test('should handle null pdfPath in JSON', () {
        final json = {
          'id': 'id',
          'title': 'title',
          'imagePaths': <String>[],
          'ocrText': '',
          'pdfPath': null,
          'createdAt': testDate.toIso8601String(),
          'updatedAt': testDate.toIso8601String(),
        };

        final doc = ScanDocument.fromJson(json);
        expect(doc.pdfPath, isNull);
      });

      test('should handle missing ocrText in JSON', () {
        final json = {
          'id': 'id',
          'title': 'title',
          'imagePaths': <String>[],
          'createdAt': testDate.toIso8601String(),
          'updatedAt': testDate.toIso8601String(),
        };

        final doc = ScanDocument.fromJson(json);
        expect(doc.ocrText, '');
      });

      test('should round-trip through JSON string encoding', () {
        final original = createTestDocument(
          imagePaths: ['/page1.png', '/page2.png'],
        );

        final jsonString = original.toJsonString();
        final decoded = ScanDocument.fromJsonString(jsonString);

        expect(decoded.id, original.id);
        expect(decoded.title, original.title);
        expect(decoded.imagePaths, original.imagePaths);
        expect(decoded.ocrText, original.ocrText);
        expect(decoded.pdfPath, original.pdfPath);
      });

      test('should produce valid JSON', () {
        final doc = createTestDocument();
        final jsonString = doc.toJsonString();

        // Should not throw
        final parsed = jsonDecode(jsonString);
        expect(parsed, isA<Map<String, dynamic>>());
      });

      test('should omit textBlocks from JSON when null', () {
        final doc = createTestDocument();
        final json = doc.toJson();
        expect(json.containsKey('textBlocks'), isFalse);
      });

      test('should round-trip textBlocks through JSON string encoding', () {
        final original = createTestDocument(textBlocks: testTextBlocks);
        final jsonString = original.toJsonString();
        final decoded = ScanDocument.fromJsonString(jsonString);

        expect(decoded.textBlocks, isNotNull);
        expect(decoded.textBlocks!.length, 1);
        final elem = decoded.textBlocks![0][0].lines[0].elements[0];
        expect(elem.text, 'Hello');
        expect(elem.left, 10.0);
        expect(elem.top, 20.0);
        expect(elem.width, 90.0);
        expect(elem.height, 20.0);
      });

      test('should handle missing textBlocks in legacy JSON', () {
        final json = {
          'id': 'id',
          'title': 'title',
          'imagePaths': <String>[],
          'ocrText': '',
          'createdAt': testDate.toIso8601String(),
          'updatedAt': testDate.toIso8601String(),
        };

        final doc = ScanDocument.fromJson(json);
        expect(doc.textBlocks, isNull);
      });
    });

    group('equality', () {
      test('should be equal when IDs match', () {
        final doc1 = createTestDocument(id: 'same-id');
        final doc2 = createTestDocument(
          id: 'same-id',
          title: 'Different Title',
        );

        expect(doc1, equals(doc2));
      });

      test('should not be equal when IDs differ', () {
        final doc1 = createTestDocument(id: 'id-1');
        final doc2 = createTestDocument(id: 'id-2');

        expect(doc1, isNot(equals(doc2)));
      });

      test('should have consistent hashCode for same ID', () {
        final doc1 = createTestDocument(id: 'same-id');
        final doc2 = createTestDocument(id: 'same-id');

        expect(doc1.hashCode, doc2.hashCode);
      });
    });

    test('toString should contain relevant info', () {
      final doc = createTestDocument(
        id: 'abc',
        title: 'My Scan',
        imagePaths: ['/p1.png', '/p2.png'],
      );

      final str = doc.toString();
      expect(str, contains('abc'));
      expect(str, contains('My Scan'));
      expect(str, contains('2'));
    });
  });
}
