import 'package:flutter_test/flutter_test.dart';
import 'package:fluxscan/services/pdf_service.dart';
import 'package:fluxscan/services/scanner_service.dart';
import 'package:image/image.dart' as img;

void main() {
  group('PdfService', () {
    test('should be instantiable', () {
      final service = PdfService();
      expect(service, isNotNull);
    });
  });

  group('ScannerService.adaptiveThreshold', () {
    test('should return an image with the same dimensions', () {
      final image = img.Image(width: 20, height: 20);
      // Fill with a uniform gray
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 20; x++) {
          image.setPixelRgb(x, y, 128, 128, 128);
        }
      }

      final result = ScannerService.adaptiveThreshold(image);

      expect(result.width, 20);
      expect(result.height, 20);
    });

    test('should produce only black and white pixels', () {
      final image = img.Image(width: 30, height: 30);
      // Create a gradient image
      for (var y = 0; y < 30; y++) {
        for (var x = 0; x < 30; x++) {
          final v = ((x + y) * 255 ~/ 58).clamp(0, 255);
          image.setPixelRgb(x, y, v, v, v);
        }
      }

      final result = ScannerService.adaptiveThreshold(image);

      for (var y = 0; y < result.height; y++) {
        for (var x = 0; x < result.width; x++) {
          final r = result.getPixel(x, y).r.toInt();
          expect(r == 0 || r == 255, isTrue,
              reason: 'Pixel ($x,$y) has value $r, expected 0 or 255');
        }
      }
    });

    test('should turn a uniform image all white', () {
      // A uniform image has no local contrast, so every pixel should
      // be >= mean - constant, resulting in all white.
      final image = img.Image(width: 20, height: 20);
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 20; x++) {
          image.setPixelRgb(x, y, 100, 100, 100);
        }
      }

      final result = ScannerService.adaptiveThreshold(image);

      for (var y = 0; y < result.height; y++) {
        for (var x = 0; x < result.width; x++) {
          expect(result.getPixel(x, y).r.toInt(), 255,
              reason: 'Uniform image should threshold to all white');
        }
      }
    });

    test('should detect dark text on a lighter background', () {
      // Create a light background with a dark center region
      final image = img.Image(width: 30, height: 30);
      for (var y = 0; y < 30; y++) {
        for (var x = 0; x < 30; x++) {
          image.setPixelRgb(x, y, 200, 200, 200);
        }
      }
      // Dark center "text" region
      for (var y = 10; y < 20; y++) {
        for (var x = 10; x < 20; x++) {
          image.setPixelRgb(x, y, 30, 30, 30);
        }
      }

      final result = ScannerService.adaptiveThreshold(image, blockSize: 15);

      // Center pixels should be black (text)
      expect(result.getPixel(15, 15).r.toInt(), 0);
      // Corner pixels should be white (background)
      expect(result.getPixel(0, 0).r.toInt(), 255);
    });

    test('should clamp blockSize to minimum of 3', () {
      final image = img.Image(width: 10, height: 10);
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 10; x++) {
          image.setPixelRgb(x, y, 128, 128, 128);
        }
      }

      // Should not throw with blockSize < 3
      final result = ScannerService.adaptiveThreshold(image, blockSize: 1);
      expect(result.width, 10);
      expect(result.height, 10);
    });

    test('should make even blockSize odd', () {
      final image = img.Image(width: 10, height: 10);
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 10; x++) {
          image.setPixelRgb(x, y, 128, 128, 128);
        }
      }

      // Even blockSize should be handled without error
      final result = ScannerService.adaptiveThreshold(image, blockSize: 10);
      expect(result.width, 10);
      expect(result.height, 10);
    });

    test('should handle color images by converting to grayscale', () {
      final image = img.Image(width: 10, height: 10);
      // Fill with a color image (red)
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 10; x++) {
          image.setPixelRgb(x, y, 255, 0, 0);
        }
      }

      // Should not throw and should produce valid B&W output
      final result = ScannerService.adaptiveThreshold(image);
      expect(result.width, 10);
      expect(result.height, 10);

      for (var y = 0; y < result.height; y++) {
        for (var x = 0; x < result.width; x++) {
          final r = result.getPixel(x, y).r.toInt();
          expect(r == 0 || r == 255, isTrue);
        }
      }
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
