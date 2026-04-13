# FluxScan

A privacy-focused, open-source document scanner built with Flutter. FluxScan is designed as an offline-first alternative to Adobe Scan — no tracking, no ads, no data collection.

## Features

- **Document Scanning**: Native edge detection and perspective correction via the device camera
- **Perspective Transformation**: Detects document corners and warps angled photos into perfect rectangular top-down views
- **OCR (Text Recognition)**: On-device text extraction using ML Kit with bundled models (works on de-Googled devices)
- **Image Enhancement**: Automatic grayscale and contrast adjustment for better scan quality
- **Searchable PDF**: Generates PDFs with invisible OCR text overlaid on scan images
- **Share & Print**: Export scans as PDFs via the system share sheet or send directly to a printer
- **100% Offline**: All processing happens on-device. No internet connection required.
- **Privacy First**: No Firebase, no analytics, no telemetry. Your documents stay on your device.

## Architecture

```
lib/
├── main.dart                     # App entry point with Material 3 theme
├── models/
│   └── scan_document.dart        # Data model for scanned documents
├── screens/
│   ├── home_screen.dart          # Main screen with recent scans list
│   ├── scan_result_screen.dart   # View scan pages and OCR text
│   └── settings_screen.dart      # App preferences
├── services/
│   ├── scanner_service.dart      # Document scanning, image processing, OCR
│   ├── perspective_service.dart  # Perspective transformation (image warping)
│   ├── pdf_service.dart          # Searchable PDF generation
│   └── storage_service.dart      # Local document persistence
└── widgets/
    └── scan_card.dart            # Document list item widget
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `cunning_document_scanner` | Native document edge detection & scanning |
| `google_mlkit_text_recognition` | On-device OCR (bundled model, no Play Services needed) |
| `image` | Image processing (grayscale, contrast, perspective warp) |
| `pdf` | PDF document generation |
| `printing` | PDF printing and preview |
| `share_plus` | System share sheet integration |
| `path_provider` | App-local file storage |
| `shared_preferences` | Settings persistence |

## Getting Started

### Prerequisites

- Flutter SDK >= 3.2.0
- Android SDK (min API 24) or Xcode for iOS

### Setup

```bash
# Clone the repository
git clone https://github.com/JohnHillen/FluxScan.git
cd FluxScan

# Install dependencies
flutter pub get

# Run on a connected device (camera required)
flutter run
```

### Android Configuration

The app is configured to use ML Kit's **bundled (static) models**, which means:
- OCR works completely offline
- Compatible with de-Googled Android (GrapheneOS, CalyxOS, LineageOS, etc.)
- No Google Play Services dependency

This is configured via the `<meta-data>` tag in `android/app/src/main/AndroidManifest.xml`:
```xml
<meta-data
    android:name="com.google.mlkit.vision.DEPENDENCIES"
    android:value="ocr" />
```

## How It Works

1. **Scan**: Tap the FAB to open the native document scanner with automatic edge detection
2. **Warp**: If document corners are detected, the image is perspective-warped into a perfect rectangular top-down view
3. **Enhance**: Images are converted to grayscale with contrast adjustment for OCR accuracy
4. **Recognize**: ML Kit extracts text with bounding box positions from each page
5. **Generate PDF**: A searchable PDF is created with the scan image as the background and invisible OCR text overlaid at the correct positions
6. **Save & Share**: Documents are stored locally and can be shared as PDF files

## Testing

```bash
flutter test
```

## License

See [LICENSE](LICENSE) for details.