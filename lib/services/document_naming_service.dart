import 'package:intl/intl.dart';

import 'scanner_service.dart';

/// Service that generates a smart document filename from OCR text of the
/// first page, using offline heuristic rules:
///
/// 1. **Date extraction** – searches for a date pattern (DD.MM.YYYY or
///    YYYY-MM-DD) in the full page text.
/// 2. **Keyword spotting** – checks whether the text contains a common German
///    document-type keyword (case-insensitive).
/// 3. **Combine** – if both a keyword and a date are found, returns
///    `"Keyword_DD-MM-YYYY"` (e.g. `"Rechnung_14-04-2026"`).
/// 4. **Fallback 1 (top-line)** – finds the [OcrTextElement] with the lowest
///    Y-coordinate that contains at least four letters, and returns its text.
/// 5. **Fallback 2 (timestamp)** – falls back to `"Scan yyyy-MM-dd_HH-mm-ss"`.
class DocumentNamingService {
  /// Known document-type keywords (German), checked case-insensitively.
  static const List<String> keywords = [
    'Rechnung',
    'Vertrag',
    'Kündigung',
    'Quittung',
    'Bescheid',
    'Gutachten',
  ];

  /// Matches DD.MM.YYYY or YYYY-MM-DD date strings.
  static final RegExp _datePattern = RegExp(
    r'\b(\d{2}\.\d{2}\.\d{4}|\d{4}-\d{2}-\d{2})\b',
  );

  /// Matches strings that contain at least four Latin letters.
  static final RegExp _wordPattern = RegExp(r'[a-zA-ZÄÖÜäöüß]{4,}');

  /// Generates a smart title for the document based on the OCR text blocks
  /// of the first page.
  ///
  /// [firstPageBlocks] – list of [OcrTextBlock] objects from the first page.
  /// [now] – optional override for the current timestamp (useful in tests).
  String generateName(
    List<OcrTextBlock> firstPageBlocks, {
    DateTime? now,
  }) {
    final text = firstPageBlocks.map((b) => b.text).join('\n');

    // --- Step 1: Date extraction ---
    final dateMatch = _datePattern.firstMatch(text);
    String? normalizedDate;
    if (dateMatch != null) {
      final raw = dateMatch.group(0)!;
      if (raw.contains('.')) {
        // DD.MM.YYYY → DD-MM-YYYY
        normalizedDate = raw.replaceAll('.', '-');
      } else {
        // YYYY-MM-DD → DD-MM-YYYY
        final parts = raw.split('-');
        normalizedDate = '${parts[2]}-${parts[1]}-${parts[0]}';
      }
    }

    // --- Step 2: Keyword spotting ---
    final lowerText = text.toLowerCase();
    String? matchedKeyword;
    for (final kw in keywords) {
      if (lowerText.contains(kw.toLowerCase())) {
        matchedKeyword = kw;
        break;
      }
    }

    // --- Step 3: Keyword + date ---
    if (matchedKeyword != null && normalizedDate != null) {
      return '${matchedKeyword}_$normalizedDate';
    }

    // --- Step 4: Fallback 1 – top-line TextElement with actual words ---
    OcrTextElement? topElement;
    double minTop = double.infinity;
    for (final block in firstPageBlocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          if (element.top < minTop && _wordPattern.hasMatch(element.text)) {
            minTop = element.top;
            topElement = element;
          }
        }
      }
    }
    if (topElement != null) {
      return topElement.text.trim();
    }

    // --- Step 5: Fallback 2 – timestamp ---
    final timestamp =
        DateFormat('yyyy-MM-dd_HH-mm-ss').format(now ?? DateTime.now());
    return 'Scan $timestamp';
  }
}
