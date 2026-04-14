import 'package:flutter_test/flutter_test.dart';
import 'package:fluxscan/services/document_naming_service.dart';
import 'package:fluxscan/services/scanner_service.dart';

/// Convenience helper to build a single-block, single-line list of
/// [OcrTextBlock] objects from a plain string (no spatial metadata needed
/// for text-only tests).
List<OcrTextBlock> _blocksFromText(String text) => [
      OcrTextBlock(
        text: text,
        left: 0,
        top: 0,
        width: 100,
        height: 20,
        lines: [
          OcrTextLine(
            text: text,
            elements: [
              OcrTextElement(
                text: text,
                left: 0,
                top: 0,
                width: 100,
                height: 20,
              ),
            ],
          ),
        ],
      ),
    ];

/// Builds an [OcrTextElement] with a custom [top] value.
OcrTextElement _element(String text, {double top = 0}) => OcrTextElement(
      text: text,
      left: 0,
      top: top,
      width: 50,
      height: 10,
    );

/// Builds a minimal block containing a single element at [top].
OcrTextBlock _blockWithElement(String text, {double top = 0}) => OcrTextBlock(
      text: text,
      left: 0,
      top: top,
      width: 100,
      height: 20,
      lines: [
        OcrTextLine(
          text: text,
          elements: [_element(text, top: top)],
        ),
      ],
    );

void main() {
  late DocumentNamingService service;
  // Fixed timestamp used wherever the fallback is expected.
  final fixedNow = DateTime(2026, 4, 14, 10, 30, 0);

  setUp(() {
    service = DocumentNamingService();
  });

  // ---------------------------------------------------------------------------
  // Step 1 + 2 + 3: keyword + date combination
  // ---------------------------------------------------------------------------

  group('keyword and date combination', () {
    test('returns Keyword_Date for DD.MM.YYYY date format', () {
      final blocks = _blocksFromText('Rechnung vom 14.04.2026');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Rechnung_14-04-2026',
      );
    });

    test('returns Keyword_Date for YYYY-MM-DD date format', () {
      final blocks = _blocksFromText('Vertrag 2026-04-14');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Vertrag_14-04-2026',
      );
    });

    test('is case-insensitive for keyword matching', () {
      final blocks = _blocksFromText('RECHNUNG 14.04.2026');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Rechnung_14-04-2026',
      );
    });

    test('matches Kündigung keyword', () {
      final blocks = _blocksFromText('Kündigung 01.01.2025');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Kündigung_01-01-2025',
      );
    });

    test('matches KÜNDIGUNG in uppercase (umlaut case-insensitive)', () {
      final blocks = _blocksFromText('KÜNDIGUNG 01.01.2025');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Kündigung_01-01-2025',
      );
    });

    test('matches Quittung keyword', () {
      final blocks = _blocksFromText('Quittung 31.12.2024');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Quittung_31-12-2024',
      );
    });

    test('matches Bescheid keyword', () {
      final blocks = _blocksFromText('Bescheid 2024-06-15');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Bescheid_15-06-2024',
      );
    });

    test('matches Gutachten keyword', () {
      final blocks = _blocksFromText('Gutachten 2023-03-20');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Gutachten_20-03-2023',
      );
    });

    test('uses first matched keyword when multiple are present', () {
      // 'Rechnung' appears before 'Vertrag' in the keywords list
      final blocks = _blocksFromText('Rechnung und Vertrag 01.01.2025');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Rechnung_01-01-2025',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Keyword only (no date) → should fall through to fallbacks
  // ---------------------------------------------------------------------------

  group('keyword without date', () {
    test('does not use keyword alone; falls to top-line element', () {
      // The only block element is 'Rechnung', which has ≥4 letters.
      final blocks = _blocksFromText('Rechnung');
      final result = service.generateName(blocks, now: fixedNow);
      // No date → keyword+date path skipped; top element 'Rechnung' returned.
      expect(result, 'Rechnung');
    });
  });

  // ---------------------------------------------------------------------------
  // Step 4: Fallback 1 – top-line element
  // ---------------------------------------------------------------------------

  group('fallback 1 – top-line TextElement', () {
    test('picks element with lowest top Y that has ≥4 letters', () {
      final blocks = [
        _blockWithElement('1234', top: 10), // no letters → skip
        _blockWithElement('Hello', top: 50), // valid but lower
        _blockWithElement('World', top: 20), // valid and higher on page
      ];
      expect(
        service.generateName(blocks, now: fixedNow),
        'World',
      );
    });

    test('skips elements with only numbers/symbols', () {
      final blocks = [
        _blockWithElement('12345', top: 5),
        _blockWithElement('!@#\$', top: 3),
        _blockWithElement('Invoice', top: 15),
      ];
      expect(
        service.generateName(blocks, now: fixedNow),
        'Invoice',
      );
    });

    test('skips elements with fewer than 4 letters', () {
      // 'Hi' has 2 letters → skip; 'Welcome' has 7 letters → use
      final blocks = [
        _blockWithElement('Hi', top: 5),
        _blockWithElement('Welcome', top: 20),
      ];
      expect(
        service.generateName(blocks, now: fixedNow),
        'Welcome',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Step 5: Fallback 2 – timestamp
  // ---------------------------------------------------------------------------

  group('fallback 2 – timestamp', () {
    test('returns scan_timestamp when no blocks', () {
      final result = service.generateName([], now: fixedNow);
      expect(result, 'Scan 2026-04-14_10-30-00');
    });

    test('returns scan_timestamp when all elements lack letters', () {
      final blocks = [
        _blockWithElement('123', top: 5),
        _blockWithElement('456', top: 10),
      ];
      final result = service.generateName(blocks, now: fixedNow);
      expect(result, 'Scan 2026-04-14_10-30-00');
    });
  });

  // ---------------------------------------------------------------------------
  // Date normalisation
  // ---------------------------------------------------------------------------

  group('date normalisation', () {
    test('converts DD.MM.YYYY to DD-MM-YYYY', () {
      final blocks = _blocksFromText('Rechnung 31.12.2025');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Rechnung_31-12-2025',
      );
    });

    test('converts YYYY-MM-DD to DD-MM-YYYY', () {
      final blocks = _blocksFromText('Rechnung 2025-12-31');
      expect(
        service.generateName(blocks, now: fixedNow),
        'Rechnung_31-12-2025',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-block text
  // ---------------------------------------------------------------------------

  group('multi-block text', () {
    test('finds keyword and date across different blocks', () {
      final blocks = [
        OcrTextBlock(
          text: 'Rechnung',
          left: 0,
          top: 0,
          width: 100,
          height: 20,
          lines: const [],
        ),
        OcrTextBlock(
          text: 'Datum: 14.04.2026',
          left: 0,
          top: 30,
          width: 200,
          height: 20,
          lines: const [],
        ),
      ];
      expect(
        service.generateName(blocks, now: fixedNow),
        'Rechnung_14-04-2026',
      );
    });
  });
}
