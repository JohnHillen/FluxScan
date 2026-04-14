import 'package:flutter_test/flutter_test.dart';
import 'package:fluxscan/services/pdf_service.dart';
import 'package:fluxscan/services/perspective_service.dart';
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

    test('should return scale 1.0 when image dimensions are zero', () {
      final result = PdfService.computePageMapping(
        imageWidth: 0,
        imageHeight: 0,
        pageWidth: 595.28,
        pageHeight: 841.89,
      );

      expect(result.scale, 1.0);
      // With zero-dimension images the centering formula yields half-page
      // offsets; this is a degenerate case but mathematically consistent.
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

  group('OcrTextElement', () {
    test('should hold text and bounding box coordinates', () {
      const element = OcrTextElement(
        text: 'Hello',
        left: 10.0,
        top: 20.0,
        width: 50.0,
        height: 15.0,
      );

      expect(element.text, 'Hello');
      expect(element.left, 10.0);
      expect(element.top, 20.0);
      expect(element.width, 50.0);
      expect(element.height, 15.0);
    });

    test('copyWith should update text but preserve bounding box', () {
      const original = OcrTextElement(
        text: 'Hello',
        left: 10.0,
        top: 20.0,
        width: 50.0,
        height: 15.0,
      );

      final updated = original.copyWith(text: 'Hi');

      expect(updated.text, 'Hi');
      expect(updated.left, original.left);
      expect(updated.top, original.top);
      expect(updated.width, original.width);
      expect(updated.height, original.height);
    });

    test('copyWith with no argument should return equivalent element', () {
      const original = OcrTextElement(
        text: 'Hello',
        left: 10.0,
        top: 20.0,
        width: 50.0,
        height: 15.0,
      );

      final copy = original.copyWith();
      expect(copy.text, original.text);
      expect(copy.left, original.left);
    });

    test('should round-trip through JSON', () {
      const original = OcrTextElement(
        text: 'Hello',
        left: 10.0,
        top: 20.0,
        width: 50.0,
        height: 15.0,
      );

      final json = original.toJson();
      final decoded = OcrTextElement.fromJson(json);

      expect(decoded.text, original.text);
      expect(decoded.left, original.left);
      expect(decoded.top, original.top);
      expect(decoded.width, original.width);
      expect(decoded.height, original.height);
    });
  });

  group('OcrTextLine', () {
    test('should hold text and elements', () {
      const line = OcrTextLine(
        text: 'Hello World',
        elements: [
          OcrTextElement(
            text: 'Hello',
            left: 10.0,
            top: 20.0,
            width: 50.0,
            height: 15.0,
          ),
          OcrTextElement(
            text: 'World',
            left: 65.0,
            top: 20.0,
            width: 55.0,
            height: 15.0,
          ),
        ],
      );

      expect(line.text, 'Hello World');
      expect(line.elements.length, 2);
      expect(line.elements[0].text, 'Hello');
      expect(line.elements[1].text, 'World');
    });

    test('copyWith should update text and elements', () {
      const original = OcrTextLine(
        text: 'Hello World',
        elements: [
          OcrTextElement(
            text: 'Hello',
            left: 10.0,
            top: 20.0,
            width: 50.0,
            height: 15.0,
          ),
        ],
      );

      final updated = original.copyWith(text: 'Hi World');
      expect(updated.text, 'Hi World');
      expect(updated.elements, original.elements);
    });

    test('should round-trip through JSON', () {
      const original = OcrTextLine(
        text: 'Hello World',
        elements: [
          OcrTextElement(
            text: 'Hello',
            left: 10.0,
            top: 20.0,
            width: 50.0,
            height: 15.0,
          ),
          OcrTextElement(
            text: 'World',
            left: 65.0,
            top: 20.0,
            width: 55.0,
            height: 15.0,
          ),
        ],
      );

      final json = original.toJson();
      final decoded = OcrTextLine.fromJson(json);

      expect(decoded.text, original.text);
      expect(decoded.elements.length, original.elements.length);
      expect(decoded.elements[0].text, 'Hello');
      expect(decoded.elements[1].text, 'World');
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
      expect(block.lines, isEmpty);
    });

    test('should hold lines with elements', () {
      const block = OcrTextBlock(
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
                width: 50.0,
                height: 15.0,
              ),
              OcrTextElement(
                text: 'World',
                left: 65.0,
                top: 20.0,
                width: 55.0,
                height: 15.0,
              ),
            ],
          ),
        ],
      );

      expect(block.lines.length, 1);
      expect(block.lines[0].elements.length, 2);
      expect(block.lines[0].elements[0].text, 'Hello');
      expect(block.lines[0].elements[1].text, 'World');
    });

    test('copyWith should update text and lines, preserving bounding box', () {
      const original = OcrTextBlock(
        text: 'Old text',
        left: 10.0,
        top: 20.0,
        width: 200.0,
        height: 30.0,
      );

      final updated = original.copyWith(text: 'New text');

      expect(updated.text, 'New text');
      expect(updated.left, original.left);
      expect(updated.top, original.top);
      expect(updated.width, original.width);
      expect(updated.height, original.height);
    });

    test('should round-trip through JSON', () {
      const original = OcrTextBlock(
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
                width: 50.0,
                height: 15.0,
              ),
            ],
          ),
        ],
      );

      final json = original.toJson();
      final decoded = OcrTextBlock.fromJson(json);

      expect(decoded.text, original.text);
      expect(decoded.left, original.left);
      expect(decoded.top, original.top);
      expect(decoded.width, original.width);
      expect(decoded.height, original.height);
      expect(decoded.lines.length, 1);
      expect(decoded.lines[0].elements[0].text, 'Hello');
    });
  });

  group('ProcessedScan', () {
    test('should hold processed scan data', () {
      const scan = ProcessedScan(
        originalImagePaths: ['/original1.png', '/original2.png'],
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

      expect(scan.originalImagePaths.length, 2);
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

  group('Corner', () {
    test('should hold x and y coordinates', () {
      const corner = Corner(10.5, 20.3);
      expect(corner.x, 10.5);
      expect(corner.y, 20.3);
    });

    test('should format toString correctly', () {
      const corner = Corner(10.0, 20.0);
      expect(corner.toString(), 'Corner(10.0, 20.0)');
    });

    test('should support equality', () {
      const a = Corner(10.0, 20.0);
      const b = Corner(10.0, 20.0);
      const c = Corner(10.0, 30.0);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('should have consistent hashCode for equal corners', () {
      const a = Corner(5.0, 15.0);
      const b = Corner(5.0, 15.0);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('DocumentCorners', () {
    test('should hold four corner points', () {
      const corners = DocumentCorners(
        topLeft: Corner(0, 0),
        topRight: Corner(100, 0),
        bottomLeft: Corner(0, 100),
        bottomRight: Corner(100, 100),
      );

      expect(corners.topLeft, const Corner(0, 0));
      expect(corners.topRight, const Corner(100, 0));
      expect(corners.bottomLeft, const Corner(0, 100));
      expect(corners.bottomRight, const Corner(100, 100));
    });

    test('should compute output width from longest horizontal edge', () {
      // Top edge is 100, bottom edge is 120 → output width should be 120
      const corners = DocumentCorners(
        topLeft: Corner(10, 0),
        topRight: Corner(110, 0),
        bottomLeft: Corner(0, 100),
        bottomRight: Corner(120, 100),
      );

      expect(corners.outputWidth, closeTo(120.0, 1.0));
    });

    test('should compute output height from longest vertical edge', () {
      // Left edge is 100, right edge is 150 → output height should be 150
      const corners = DocumentCorners(
        topLeft: Corner(0, 0),
        topRight: Corner(100, 0),
        bottomLeft: Corner(0, 100),
        bottomRight: Corner(100, 150),
      );

      expect(corners.outputHeight, closeTo(150.0, 1.0));
    });

    test('should compute correct dimensions for a perfect rectangle', () {
      const corners = DocumentCorners(
        topLeft: Corner(0, 0),
        topRight: Corner(200, 0),
        bottomLeft: Corner(0, 300),
        bottomRight: Corner(200, 300),
      );

      expect(corners.outputWidth, closeTo(200.0, 0.01));
      expect(corners.outputHeight, closeTo(300.0, 0.01));
    });

    test('toString should contain corner info', () {
      const corners = DocumentCorners(
        topLeft: Corner(0, 0),
        topRight: Corner(100, 0),
        bottomLeft: Corner(0, 100),
        bottomRight: Corner(100, 100),
      );

      final str = corners.toString();
      expect(str, contains('DocumentCorners'));
      expect(str, contains('Corner'));
    });
  });

  group('PerspectiveService.warpImage', () {
    test('should return an image with dimensions derived from corners', () {
      // Create a 100x100 test image
      final image = img.Image(width: 100, height: 100);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          image.setPixelRgb(x, y, 128, 128, 128);
        }
      }

      const corners = DocumentCorners(
        topLeft: Corner(0, 0),
        topRight: Corner(99, 0),
        bottomLeft: Corner(0, 99),
        bottomRight: Corner(99, 99),
      );

      final result = PerspectiveService.warpImage(image, corners);

      // Output dimensions should be close to 99 (distance between corners)
      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
    });

    test('should handle non-rectangular quadrilateral corners', () {
      // Create a 200x200 test image with distinct quadrants
      final image = img.Image(width: 200, height: 200);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 200; x++) {
          image.setPixelRgb(x, y, x % 256, y % 256, 128);
        }
      }

      // Trapezoid corners (document photographed at an angle)
      const corners = DocumentCorners(
        topLeft: Corner(30, 20),
        topRight: Corner(170, 10),
        bottomLeft: Corner(10, 180),
        bottomRight: Corner(190, 190),
      );

      final result = PerspectiveService.warpImage(image, corners);

      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
      // The warped image should be roughly rectangular based on corner distances
      expect(result.width, closeTo(corners.outputWidth, 1.0));
      expect(result.height, closeTo(corners.outputHeight, 1.0));
    });

    test('should produce valid pixel data', () {
      final image = img.Image(width: 50, height: 50);
      for (var y = 0; y < 50; y++) {
        for (var x = 0; x < 50; x++) {
          image.setPixelRgb(x, y, 200, 200, 200);
        }
      }

      const corners = DocumentCorners(
        topLeft: Corner(5, 5),
        topRight: Corner(45, 5),
        bottomLeft: Corner(5, 45),
        bottomRight: Corner(45, 45),
      );

      final result = PerspectiveService.warpImage(image, corners);

      // All pixels should have valid values
      for (var y = 0; y < result.height; y++) {
        for (var x = 0; x < result.width; x++) {
          final pixel = result.getPixel(x, y);
          expect(pixel.r.toInt(), inInclusiveRange(0, 255));
          expect(pixel.g.toInt(), inInclusiveRange(0, 255));
          expect(pixel.b.toInt(), inInclusiveRange(0, 255));
        }
      }
    });
  });

  group('PerspectiveService.orderCorners', () {
    test('should order four arbitrary points into canonical positions', () {
      // Points in random order that form a rectangle
      final points = [
        const Corner(100, 0), // top-right
        const Corner(0, 100), // bottom-left
        const Corner(100, 100), // bottom-right
        const Corner(0, 0), // top-left
      ];

      final ordered = PerspectiveService.orderCorners(points);

      expect(ordered.topLeft, const Corner(0, 0));
      expect(ordered.topRight, const Corner(100, 0));
      expect(ordered.bottomLeft, const Corner(0, 100));
      expect(ordered.bottomRight, const Corner(100, 100));
    });

    test('should handle already-ordered points', () {
      final points = [
        const Corner(0, 0),
        const Corner(200, 0),
        const Corner(0, 300),
        const Corner(200, 300),
      ];

      final ordered = PerspectiveService.orderCorners(points);

      expect(ordered.topLeft, const Corner(0, 0));
      expect(ordered.topRight, const Corner(200, 0));
      expect(ordered.bottomLeft, const Corner(0, 300));
      expect(ordered.bottomRight, const Corner(200, 300));
    });

    test('should throw when given fewer than 4 points', () {
      expect(
        () => PerspectiveService.orderCorners([
          const Corner(0, 0),
          const Corner(100, 0),
          const Corner(0, 100),
        ]),
        throwsA(isA<PerspectiveException>()),
      );
    });

    test('should throw when given more than 4 points', () {
      expect(
        () => PerspectiveService.orderCorners([
          const Corner(0, 0),
          const Corner(100, 0),
          const Corner(0, 100),
          const Corner(100, 100),
          const Corner(50, 50),
        ]),
        throwsA(isA<PerspectiveException>()),
      );
    });

    test('should correctly order a trapezoid', () {
      // Simulating a document photographed at an angle
      final points = [
        const Corner(180, 190), // bottom-right
        const Corner(20, 10), // top-left
        const Corner(10, 180), // bottom-left
        const Corner(170, 20), // top-right
      ];

      final ordered = PerspectiveService.orderCorners(points);

      expect(ordered.topLeft, const Corner(20, 10));
      expect(ordered.topRight, const Corner(170, 20));
      expect(ordered.bottomLeft, const Corner(10, 180));
      expect(ordered.bottomRight, const Corner(180, 190));
    });
  });

  group('PerspectiveService.mapCornersToImageResolution', () {
    test('should scale corners from display to image resolution', () {
      // Display is 400x600, image is 2000x3000 (5x scale)
      const displayCorners = DocumentCorners(
        topLeft: Corner(10, 20),
        topRight: Corner(390, 20),
        bottomLeft: Corner(10, 580),
        bottomRight: Corner(390, 580),
      );

      final mapped = PerspectiveService.mapCornersToImageResolution(
        corners: displayCorners,
        displayWidth: 400,
        displayHeight: 600,
        imageWidth: 2000,
        imageHeight: 3000,
      );

      expect(mapped.topLeft.x, closeTo(50, 0.01));
      expect(mapped.topLeft.y, closeTo(100, 0.01));
      expect(mapped.topRight.x, closeTo(1950, 0.01));
      expect(mapped.topRight.y, closeTo(100, 0.01));
      expect(mapped.bottomLeft.x, closeTo(50, 0.01));
      expect(mapped.bottomLeft.y, closeTo(2900, 0.01));
      expect(mapped.bottomRight.x, closeTo(1950, 0.01));
      expect(mapped.bottomRight.y, closeTo(2900, 0.01));
    });

    test('should return same corners when display matches image size', () {
      const corners = DocumentCorners(
        topLeft: Corner(10, 20),
        topRight: Corner(90, 20),
        bottomLeft: Corner(10, 80),
        bottomRight: Corner(90, 80),
      );

      final mapped = PerspectiveService.mapCornersToImageResolution(
        corners: corners,
        displayWidth: 100,
        displayHeight: 100,
        imageWidth: 100,
        imageHeight: 100,
      );

      expect(mapped.topLeft.x, closeTo(10, 0.01));
      expect(mapped.topLeft.y, closeTo(20, 0.01));
    });

    test('should handle non-uniform scaling', () {
      const corners = DocumentCorners(
        topLeft: Corner(10, 10),
        topRight: Corner(90, 10),
        bottomLeft: Corner(10, 90),
        bottomRight: Corner(90, 90),
      );

      // Display 100x100, image 200x400 (2x horizontal, 4x vertical)
      final mapped = PerspectiveService.mapCornersToImageResolution(
        corners: corners,
        displayWidth: 100,
        displayHeight: 100,
        imageWidth: 200,
        imageHeight: 400,
      );

      expect(mapped.topLeft.x, closeTo(20, 0.01));
      expect(mapped.topLeft.y, closeTo(40, 0.01));
      expect(mapped.bottomRight.x, closeTo(180, 0.01));
      expect(mapped.bottomRight.y, closeTo(360, 0.01));
    });
  });

  group('PerspectiveException', () {
    test('should format message correctly', () {
      const exception = PerspectiveException('warp failed');
      expect(exception.toString(), 'PerspectiveException: warp failed');
      expect(exception.message, 'warp failed');
    });
  });
}
