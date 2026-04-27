import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'screens/home_screen.dart';

/// FluxScan — A privacy-focused, open-source document scanner.
///
/// All document processing (edge detection, OCR, PDF generation) is
/// performed entirely on-device. No data ever leaves the user's phone.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required when using PdfDocument directly (without a pdfrx viewer widget)
  // to ensure the cache directory and engine are properly initialised.
  pdfrxFlutterInitialize();
  runApp(
    const ProviderScope(
      child: FluxScanApp(),
    ),
  );
}

/// Root application widget with Material 3 theming.
class FluxScanApp extends StatelessWidget {
  const FluxScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FluxScan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
