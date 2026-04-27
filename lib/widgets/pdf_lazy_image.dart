import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// A widget that renders a PDF page on demand.
/// Used for high-performance lazy rendering of PDF documents.
class PdfLazyImage extends StatelessWidget {
  final PdfDocument pdfDocument;
  final int pageIndex;
  final BoxFit fit;

  const PdfLazyImage({
    super.key,
    required this.pdfDocument,
    required this.pageIndex,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    if (pageIndex < 0 || pageIndex >= pdfDocument.pages.length) {
      return const Center(child: Icon(Icons.error));
    }


    return LayoutBuilder(
      builder: (context, constraints) {
        return PdfPageView(
          document: pdfDocument,
          pageNumber: pageIndex + 1, // pdfrx uses 1-based page numbers
        );
      },
    );
  }
}
