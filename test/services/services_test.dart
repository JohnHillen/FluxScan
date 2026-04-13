import 'package:flutter_test/flutter_test.dart';
import 'package:fluxscan/services/pdf_service.dart';
import 'package:fluxscan/services/scanner_service.dart';

void main() {
  group('PdfService', () {
    test('should be instantiable', () {
      final service = PdfService();
      expect(service, isNotNull);
    });
  });

  group('OcrTextBlock', () {
    test('should hold text and bounding box coordinates', () {
      const block = OcrTextBlock(
        text: 'Hello World',
        left: 10.0,
        top: 20.0,
        width: 200.0,
        height: 30.0,
      );

      expect(block.text, 'Hello World');
      expect(block.left, 10.0);
      expect(block.top, 20.0);
      expect(block.width, 200.0);
      expect(block.height, 30.0);
    });
  });

  group('ProcessedScan', () {
    test('should hold processed scan data', () {
      const scan = ProcessedScan(
        enhancedImagePaths: ['/enhanced1.png', '/enhanced2.png'],
        textBlocks: [
          [
            OcrTextBlock(
              text: 'Page 1 text',
              left: 0,
              top: 0,
              width: 100,
              height: 20,
            ),
          ],
          [
            OcrTextBlock(
              text: 'Page 2 text',
              left: 0,
              top: 0,
              width: 100,
              height: 20,
            ),
          ],
        ],
        combinedText: 'Page 1 text\n\n--- Page Break ---\n\nPage 2 text',
      );

      expect(scan.enhancedImagePaths.length, 2);
      expect(scan.textBlocks.length, 2);
      expect(scan.combinedText, contains('Page 1 text'));
      expect(scan.combinedText, contains('Page 2 text'));
    });
  });

  group('ScannerException', () {
    test('should format message correctly', () {
      const exception = ScannerException('test error');
      expect(exception.toString(), 'ScannerException: test error');
      expect(exception.message, 'test error');
    });
  });
}
