/// Sanitizes a document title into a safe PDF filename.
///
/// Removes characters that are unsafe for filenames, collapses
/// consecutive dots to prevent path traversal patterns, and
/// falls back to 'document.pdf' if the sanitized result is empty.
String sanitizedPdfFilename(String title) {
  // Allow only word characters, spaces, hyphens, and single dots
  var sanitized = title.replaceAll(RegExp(r'[^\w\s\-]'), '').trim();

  if (sanitized.isEmpty) {
    return 'document.pdf';
  }

  return '$sanitized.pdf';
}
