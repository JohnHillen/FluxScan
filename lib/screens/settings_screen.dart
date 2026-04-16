import 'package:flutter/material.dart';

/// Settings screen for app preferences.
///
/// Provides privacy-respecting configuration options with all
/// settings stored locally on the device.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _buildSectionHeader(context, 'About'),
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
