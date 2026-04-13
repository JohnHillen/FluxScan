import 'package:flutter_test/flutter_test.dart';
import 'package:fluxscan/utils/filename_utils.dart';

void main() {
  group('sanitizedPdfFilename', () {
    test('should append .pdf to a normal title', () {
      expect(sanitizedPdfFilename('My Document'), 'My Document.pdf');
    });

    test('should remove special characters', () {
      expect(sanitizedPdfFilename('Scan @#\$%'), 'Scan .pdf');
    });

    test('should fall back to document.pdf for empty result', () {
      expect(sanitizedPdfFilename(''), 'document.pdf');
      expect(sanitizedPdfFilename('@#\$%'), 'document.pdf');
    });

    test('should keep word characters, spaces, and hyphens', () {
      expect(
        sanitizedPdfFilename('Scan 2024-01-15'),
        'Scan 2024-01-15.pdf',
      );
    });

    test('should trim whitespace', () {
      expect(sanitizedPdfFilename('  My Scan  '), 'My Scan.pdf');
    });
  });
}
