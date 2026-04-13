import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings screen for app preferences.
///
/// Provides privacy-respecting configuration options with all
/// settings stored locally on the device.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoEnhance = true;
  bool _autoOcr = true;
  bool _autoPdf = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _autoEnhance = prefs.getBool('autoEnhance') ?? true;
        _autoOcr = prefs.getBool('autoOcr') ?? true;
        _autoPdf = prefs.getBool('autoPdf') ?? true;
      });
    }
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _buildSectionHeader('Scan Settings'),
          SwitchListTile(
            title: const Text('Auto-enhance images'),
            subtitle: const Text(
              'Apply grayscale and contrast adjustment to improve scan quality',
            ),
            value: _autoEnhance,
            onChanged: (value) {
              setState(() => _autoEnhance = value);
              _saveSetting('autoEnhance', value);
            },
          ),
          SwitchListTile(
            title: const Text('Auto-run OCR'),
            subtitle: const Text(
              'Automatically extract text from scanned images',
            ),
            value: _autoOcr,
            onChanged: (value) {
              setState(() => _autoOcr = value);
              _saveSetting('autoOcr', value);
            },
          ),
          SwitchListTile(
            title: const Text('Auto-generate PDF'),
            subtitle: const Text(
              'Automatically create a searchable PDF after scanning',
            ),
            value: _autoPdf,
            onChanged: (value) {
              setState(() => _autoPdf = value);
              _saveSetting('autoPdf', value);
            },
          ),
          const Divider(),
          _buildSectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('FluxScan'),
            subtitle: const Text(
              'Privacy-focused document scanner\n'
              'Version 1.0.0',
            ),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Privacy'),
            subtitle: const Text(
              'All processing is done on-device.\n'
              'No data is sent to any server.\n'
              'No tracking. No analytics. No ads.',
            ),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Open Source'),
            subtitle: const Text(
              'FluxScan is free and open-source software.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
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
