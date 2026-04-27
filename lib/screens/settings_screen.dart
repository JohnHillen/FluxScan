import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/settings_provider.dart';

/// Settings screen for app preferences.
///
/// Provides privacy-respecting configuration options with all
/// settings stored locally on the device.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _showColorPicker(BuildContext context, WidgetRef ref, Color currentColor) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Farbe wählen'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: currentColor,
              onColorChanged: (color) {
                ref.read(settingsProvider.notifier).setOcrTextColor(color);
              },
              pickerAreaHeightPercent: 0.8,
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Fertig'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _buildSectionHeader(context, 'Editor'),
          ListTile(
            leading: const Icon(Icons.color_lens_outlined),
            title: const Text('OCR Textfarbe'),
            subtitle: const Text('Wählen Sie die Farbe für die Texterkennung'),
            trailing: GestureDetector(
              onTap: () => _showColorPicker(context, ref, settings.ocrTextColor),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: settings.ocrTextColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
              ),
            ),
            onTap: () => _showColorPicker(context, ref, settings.ocrTextColor),
          ),
          const SizedBox(height: 16),

          _buildSectionHeader(context, 'About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('FluxScan'),
            subtitle: Text(
              'Privacy-focused document scanner\n'
              'Version 1.0.0',
            ),
            isThreeLine: true,
          ),
          const ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('Privacy'),
            subtitle: Text(
              'All processing is done on-device.\n'
              'No data is sent to any server.\n'
              'No tracking. No analytics. No ads.',
            ),
            isThreeLine: true,
          ),
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('Open Source'),
            subtitle: Text(
              'FluxScan is free and open-source software.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
