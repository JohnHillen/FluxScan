import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsState {
  final Color ocrTextColor;

  SettingsState({
    required this.ocrTextColor,
  });

  SettingsState copyWith({
    Color? ocrTextColor,
  }) {
    return SettingsState(
      ocrTextColor: ocrTextColor ?? this.ocrTextColor,
    );
  }
}

class SettingsNotifier extends Notifier<SettingsState> {
  static const _keyOcrColor = 'ocr_text_color';

  @override
  SettingsState build() {
    // We can't use async in build() directly for the initial state if we want it synchronous.
    // However, we can use a "default" and then load from prefs.
    // For Riverpod 3.x Notifier, it's better to use AsyncNotifier if we want to wait for prefs,
    // or just initialize with defaults and load asynchronously.
    
    _loadSettings();
    
    return SettingsState(
      ocrTextColor: Colors.yellow, // Default color
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_keyOcrColor);
    if (colorValue != null) {
      state = state.copyWith(ocrTextColor: Color(colorValue));
    }
  }

  Future<void> setOcrTextColor(Color color) async {
    state = state.copyWith(ocrTextColor: color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyOcrColor, color.value);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, SettingsState>(() {
  return SettingsNotifier();
});
