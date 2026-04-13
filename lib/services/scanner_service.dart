import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'perspective_service.dart';

/// Top-level function for running image enhancement in a background isolate.
///
/// Takes raw image bytes, decodes them, applies adaptive thresholding, and
/// returns the enhanced image as PNG-encoded bytes. Must be a top-level
/// function so it can be passed to [compute].
Uint8List _enhanceImageIsolate(Uint8List imageBytes) {
  final original = img.decodeImage(imageBytes);
  if (original == null) {
    throw Exception('Failed to decode image in isolate');
  }
  final enhanced = ScannerService.adaptiveThreshold(original);
  return Uint8List.fromList(img.encodePng(enhanced));
}

/// Service responsible for document scanning, image processing, and OCR.
///
/// Uses the device's native document scanner for edge detection and
/// perspective correction, then applies image enhancement filters
/// before running on-device OCR via ML Kit (bundled model).
///
/// When document corners are provided, a [PerspectiveService] step is
/// applied AFTER scanning but BEFORE image enhancement and OCR, ensuring
/// the OCR engine works on a perfectly rectangular top-down image.
class ScannerService {
  static const _uuid = Uuid();

  /// Service for perspective transformation (image warping).
  final PerspectiveService _perspectiveService = PerspectiveService();

  /// The ML Kit text recognizer configured for Latin script.
  ///
  /// Latin script covers English, German, and most Western European languages.
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  /// Opens the native document scanner and returns the scanned image paths.
  ///
  /// Uses the device's built-in document detection which handles
  /// edge detection, perspective correction, and cropping.
  ///
  /// Returns an empty list if the user cancels the scan.
  Future<List<String>> scanDocument() async {
    try {
      final images = await CunningDocumentScanner.getPictures(
        isGalleryImportAllowed: true,
      );
      return images ?? [];
    } catch (e) {
      throw ScannerException('Failed to scan document: $e');
    }
  }

  /// Applies adaptive thresholding to produce a high-contrast black and white
  /// image with shadows removed.
  ///
  /// Uses a mean-based adaptive threshold computed over a local
  /// [blockSize]×[blockSize] neighborhood. A pixel is set to white if its
  /// intensity exceeds the local mean minus [constant]; otherwise it is set
  /// to black. This removes uneven lighting and shadows common in phone
  /// camera scans.
  ///
  /// An integral image (summed area table) is used internally so the
  /// block-mean lookup for every pixel runs in constant time, keeping the
  /// overall complexity at O(width × height).
  ///
  /// [image] - The source image (converted to grayscale internally).
  /// [blockSize] - Side length of the local neighborhood (must be odd, ≥ 3).
  ///   Defaults to 15.
  /// [constant] - Value subtracted from the local mean before comparison.
  ///   Higher values preserve more detail but may retain noise. Defaults to 10.
  static img.Image adaptiveThreshold(
    img.Image image, {
    int blockSize = 15,
    int constant = 10,
  }) {
    // Ensure blockSize is odd and at least 3
    blockSize = math.max(blockSize, 3);
    if (blockSize.isEven) blockSize += 1;

    final grayscale = img.grayscale(img.Image.from(image));
    final width = grayscale.width;
    final height = grayscale.height;

    // Build integral image (summed area table) for O(1) block mean queries.
    // integral[y+1][x+1] = sum of all pixel intensities in (0..x, 0..y).
    final integral = List<List<int>>.generate(
      height + 1,
      (_) => List<int>.filled(width + 1, 0),
    );

    for (var y = 0; y < height; y++) {
      var rowSum = 0;
      for (var x = 0; x < width; x++) {
        rowSum += grayscale.getPixel(x, y).r.toInt();
        integral[y + 1][x + 1] = integral[y][x + 1] + rowSum;
      }
    }

    // Apply adaptive threshold using the integral image.
    final output = img.Image(width: width, height: height);
    final halfBlock = blockSize ~/ 2;

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        // Clamp block boundaries to image edges
        final x1 = math.max(x - halfBlock, 0);
        final y1 = math.max(y - halfBlock, 0);
        final x2 = math.min(x + halfBlock, width - 1);
        final y2 = math.min(y + halfBlock, height - 1);

        final count = (x2 - x1 + 1) * (y2 - y1 + 1);

        // Summed area table lookup for the rectangle (x1..x2, y1..y2)
        final sum = integral[y2 + 1][x2 + 1]
            - integral[y1][x2 + 1]
            - integral[y2 + 1][x1]
            + integral[y1][x1];

        final mean = sum ~/ count;
        final intensity = grayscale.getPixel(x, y).r.toInt();

        // Pixel is foreground (black) if below local mean minus constant
        final value = intensity < (mean - constant) ? 0 : 255;
        output.setPixelRgb(x, y, value, value, value);
      }
    }

    return output;
  }

  /// Enhances a scanned image for better OCR accuracy.
  ///
  /// Applies adaptive thresholding to remove shadows and convert the scan
  /// to a high-contrast black and white image, improving text readability
  /// for the OCR engine. The enhanced image is saved to a new file.
  ///
  /// The CPU-intensive image processing (decode, threshold, encode) is
  /// offloaded to a background isolate via [compute] to keep the UI
  /// responsive during processing.
  ///
  /// Returns the file path to the enhanced image.
  Future<String> enhanceImage(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();

      // Offload CPU-intensive image processing to a background isolate
      final encodedBytes = await compute(_enhanceImageIsolate, bytes);

      // Save the enhanced image
      final dir = await getApplicationDocumentsDirectory();
      final enhancedPath =
          '${dir.path}/enhanced_${_uuid.v4()}.png';
      await File(enhancedPath).writeAsBytes(encodedBytes);

      return enhancedPath;
    } catch (e) {
      if (e is ScannerException) rethrow;
      throw ScannerException('Failed to enhance image: $e');
    }
  }

  /// Performs OCR on the given image and returns the extracted text.
  ///
  /// Uses the on-device ML Kit text recognizer with the bundled Latin
  /// script model, ensuring it works offline and on de-Googled devices.
  Future<String> recognizeText(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognized = await _textRecognizer.processImage(inputImage);
      return recognized.text;
    } catch (e) {
      throw ScannerException('Failed to recognize text: $e');
    }
  }

  /// Performs OCR on the given image and returns structured text blocks.
  ///
  /// Each block contains the recognized text and its bounding box
  /// relative to the original image, used for creating searchable PDFs.
  /// Blocks include line-level and element-level (word) data with
  /// individual bounding boxes for precise PDF text overlay alignment.
  Future<List<OcrTextBlock>> recognizeTextBlocks(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognized = await _textRecognizer.processImage(inputImage);

      return recognized.blocks.map((block) {
        final lines = block.lines.map((line) {
          final elements = line.elements.map((element) {
            return OcrTextElement(
              text: element.text,
              left: element.boundingBox.left,
              top: element.boundingBox.top,
              width: element.boundingBox.width,
              height: element.boundingBox.height,
            );
          }).toList();

          return OcrTextLine(
            text: line.text,
            elements: elements,
          );
        }).toList();

        return OcrTextBlock(
          text: block.text,
          left: block.boundingBox.left,
          top: block.boundingBox.top,
          width: block.boundingBox.width,
          height: block.boundingBox.height,
          lines: lines,
        );
      }).toList();
    } catch (e) {
      throw ScannerException('Failed to recognize text blocks: $e');
    }
  }

  /// Processes a list of scanned images: optionally warps perspective,
  /// enhances each, then runs OCR.
  ///
  /// If [corners] is provided, a perspective warp is applied to each image
  /// BEFORE enhancement and OCR. Each entry in [corners] corresponds to
  /// the image at the same index in [imagePaths]. A `null` entry means
  /// no perspective correction for that page.
  ///
  /// Returns a [ProcessedScan] containing the enhanced image paths and
  /// the combined OCR text from all pages.
  Future<ProcessedScan> processImages(
    List<String> imagePaths, {
    List<DocumentCorners?>? corners,
  }) async {
    final originalPaths = <String>[];
    final enhancedPaths = <String>[];
    final allTextBlocks = <List<OcrTextBlock>>[];
    final allText = StringBuffer();

    for (var i = 0; i < imagePaths.length; i++) {
      var currentPath = imagePaths[i];

      // Step 1: Apply perspective warp if corners are provided for this page
      if (corners != null && i < corners.length && corners[i] != null) {
        currentPath = await _perspectiveService.warpImageFile(
          currentPath,
          corners[i]!,
        );
      }

      // Keep the original (post-warp, pre-enhance) path for display / PDF
      originalPaths.add(currentPath);

      // Step 2: Enhance the image for OCR
      final enhancedPath = await enhanceImage(currentPath);
      enhancedPaths.add(enhancedPath);

      // Step 3: Run OCR on the enhanced image
      final textBlocks = await recognizeTextBlocks(enhancedPath);
      allTextBlocks.add(textBlocks);

      final pageText = textBlocks.map((b) => b.text).join('\n');
      if (allText.isNotEmpty && pageText.isNotEmpty) {
        allText.write('\n\n--- Page Break ---\n\n');
      }
      allText.write(pageText);
    }

    return ProcessedScan(
      originalImagePaths: originalPaths,
      enhancedImagePaths: enhancedPaths,
      textBlocks: allTextBlocks,
      combinedText: allText.toString(),
    );
  }

  /// Releases resources held by the text recognizer.
  void dispose() {
    _textRecognizer.close();
  }
}

/// Holds a single OCR text element (word) with its bounding box coordinates.
class OcrTextElement {
  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  const OcrTextElement({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// Holds a single OCR text line with its elements (words).
class OcrTextLine {
  final String text;
  final List<OcrTextElement> elements;

  const OcrTextLine({
    required this.text,
    required this.elements,
  });
}

/// Holds a single OCR text block with its bounding box coordinates
/// and structured line/element data for precise PDF text overlay.
class OcrTextBlock {
  final String text;
  final double left;
  final double top;
  final double width;
  final double height;
  final List<OcrTextLine> lines;

  const OcrTextBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.lines = const [],
  });
}

/// Result of processing scanned images through enhancement and OCR.
class ProcessedScan {
  /// Original (pre-enhancement) image file paths (one per page).
  ///
  /// These retain the full colour information of the scan and are used
  /// for display in the app and as the visual layer in the exported PDF.
  final List<String> originalImagePaths;

  /// Enhanced image file paths (one per page).
  final List<String> enhancedImagePaths;

  /// Structured OCR text blocks per page.
  final List<List<OcrTextBlock>> textBlocks;

  /// All OCR text combined into a single string.
  final String combinedText;

  const ProcessedScan({
    required this.originalImagePaths,
    required this.enhancedImagePaths,
    required this.textBlocks,
    required this.combinedText,
  });
}

/// Exception thrown by [ScannerService] operations.
class ScannerException implements Exception {
  final String message;
  const ScannerException(this.message);

  @override
  String toString() => 'ScannerException: $message';
}
