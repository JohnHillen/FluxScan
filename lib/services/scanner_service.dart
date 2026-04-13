import 'dart:io';
import 'dart:typed_data';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Service responsible for document scanning, image processing, and OCR.
///
/// Uses the device's native document scanner for edge detection and
/// perspective correction, then applies image enhancement filters
/// before running on-device OCR via ML Kit (bundled model).
class ScannerService {
  static const _uuid = Uuid();

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

  /// Enhances a scanned image for better OCR accuracy.
  ///
  /// Applies grayscale conversion and contrast adjustment to improve
  /// text readability. The enhanced image is saved to a new file.
  ///
  /// Returns the file path to the enhanced image.
  Future<String> enhanceImage(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) {
        throw ScannerException('Failed to decode image: $imagePath');
      }

      // Convert to grayscale for better OCR results
      final grayscale = img.grayscale(original);

      // Adjust contrast to make text stand out
      final enhanced = img.adjustColor(grayscale, contrast: 1.3);

      // Save the enhanced image
      final dir = await getApplicationDocumentsDirectory();
      final enhancedPath =
          '${dir.path}/enhanced_${_uuid.v4()}.png';
      final encodedBytes = img.encodePng(enhanced);
      await File(enhancedPath).writeAsBytes(Uint8List.fromList(encodedBytes));

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
  Future<List<OcrTextBlock>> recognizeTextBlocks(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognized = await _textRecognizer.processImage(inputImage);

      return recognized.blocks.map((block) {
        return OcrTextBlock(
          text: block.text,
          left: block.boundingBox.left,
          top: block.boundingBox.top,
          width: block.boundingBox.width,
          height: block.boundingBox.height,
        );
      }).toList();
    } catch (e) {
      throw ScannerException('Failed to recognize text blocks: $e');
    }
  }

  /// Processes a list of scanned images: enhances each, then runs OCR.
  ///
  /// Returns a [ProcessedScan] containing the enhanced image paths and
  /// the combined OCR text from all pages.
  Future<ProcessedScan> processImages(List<String> imagePaths) async {
    final enhancedPaths = <String>[];
    final allTextBlocks = <List<OcrTextBlock>>[];
    final allText = StringBuffer();

    for (final path in imagePaths) {
      // Enhance the image for OCR
      final enhancedPath = await enhanceImage(path);
      enhancedPaths.add(enhancedPath);

      // Run OCR on the enhanced image
      final textBlocks = await recognizeTextBlocks(enhancedPath);
      allTextBlocks.add(textBlocks);

      final pageText = textBlocks.map((b) => b.text).join('\n');
      if (allText.isNotEmpty && pageText.isNotEmpty) {
        allText.write('\n\n--- Page Break ---\n\n');
      }
      allText.write(pageText);
    }

    return ProcessedScan(
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

/// Holds a single OCR text block with its bounding box coordinates.
class OcrTextBlock {
  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  const OcrTextBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// Result of processing scanned images through enhancement and OCR.
class ProcessedScan {
  /// Enhanced image file paths (one per page).
  final List<String> enhancedImagePaths;

  /// Structured OCR text blocks per page.
  final List<List<OcrTextBlock>> textBlocks;

  /// All OCR text combined into a single string.
  final String combinedText;

  const ProcessedScan({
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
