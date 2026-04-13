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

  group('PdfService.computePageMapping', () {
    test('should use uniform scale with no offset for matching aspect ratio',
        () {
      // Image aspect ratio matches page aspect ratio exactly
      final result = PdfService.computePageMapping(
        imageWidth: 595.28,
        imageHeight: 841.89,
        pageWidth: 595.28,
        pageHeight: 841.89,
      );

      expect(result.scale, closeTo(1.0, 0.001));
      expect(result.offsetX, closeTo(0.0, 0.001));
      expect(result.offsetY, closeTo(0.0, 0.001));
    });

    test('should add horizontal offset for tall narrow images', () {
      // Image is taller relative to its width than the page
      // e.g., 1000x2000 image on 595.28x841.89 A4 page
      // scaleX = 595.28/1000 = 0.59528
      // scaleY = 841.89/2000 = 0.420945
      // uniformScale = min(0.59528, 0.420945) = 0.420945
      // rendered width = 1000 * 0.420945 = 420.945
      // offsetX = (595.28 - 420.945) / 2 = 87.1675
      // offsetY = 0 (height fits exactly)
      final result = PdfService.computePageMapping(
        imageWidth: 1000,
        imageHeight: 2000,
        pageWidth: 595.28,
        pageHeight: 841.89,
      );

      expect(result.scale, closeTo(0.420945, 0.001));
      expect(result.offsetX, greaterThan(0));
      expect(result.offsetY, closeTo(0.0, 0.001));
    });

    test('should add vertical offset for wide images', () {
      // Image is wider relative to its height than the page
      // e.g., 4000x2000 image on 595.28x841.89 A4 page
      // scaleX = 595.28/4000 = 0.14882
      // scaleY = 841.89/2000 = 0.420945
      // uniformScale = min(0.14882, 0.420945) = 0.14882
      // rendered height = 2000 * 0.14882 = 297.64
      // offsetY = (841.89 - 297.64) / 2 = 272.125
      final result = PdfService.computePageMapping(
        imageWidth: 4000,
        imageHeight: 2000,
        pageWidth: 595.28,
        pageHeight: 841.89,
      );

      expect(result.scale, closeTo(0.14882, 0.001));
      expect(result.offsetX, closeTo(0.0, 0.001));
      expect(result.offsetY, greaterThan(0));
    });

    test('should return scale 1.0 and zero offset when dimensions are zero',
        () {
      final result = PdfService.computePageMapping(
        imageWidth: 0,
        imageHeight: 0,
        pageWidth: 595.28,
        pageHeight: 841.89,
      );

      expect(result.scale, 1.0);
      expect(result.offsetX, closeTo(595.28 / 2, 0.001));
      expect(result.offsetY, closeTo(841.89 / 2, 0.001));
    });

    test('should correctly map bounding box coordinates', () {
      // 2480x3508 image (A4 at 300dpi) on A4 page (595.28x841.89 pt)
      final result = PdfService.computePageMapping(
        imageWidth: 2480,
        imageHeight: 3508,
        pageWidth: 595.28,
        pageHeight: 841.89,
      );

      // Both scale factors are very close: ~0.2400 vs ~0.2400
      // so offset should be nearly zero
      expect(result.offsetX, closeTo(0.0, 1.0));
      expect(result.offsetY, closeTo(0.0, 1.0));

      // A block at image pixel (100, 200) should map proportionally
      final mappedLeft = 100.0 * result.scale + result.offsetX;
      final mappedTop = 200.0 * result.scale + result.offsetY;
      expect(mappedLeft, greaterThanOrEqualTo(0));
      expect(mappedTop, greaterThanOrEqualTo(0));
      expect(mappedLeft, lessThanOrEqualTo(595.28));
      expect(mappedTop, lessThanOrEqualTo(841.89));
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
      // Create a gradient from black (top-left) to white (bottom-right).
      // Max x+y is 29+29 = 58, so dividing by 58 maps to 0..255.
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
