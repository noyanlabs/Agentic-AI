// Strictly black and white. Color is reserved for special boxes only (warning red, info blue, success green, vision purple).
import 'package:flutter/material.dart';

class Palette {
  final Color background, surface, surfaceAlt, border, text, textDim, inverse, onInverse;
  const Palette({required this.background, required this.surface, required this.surfaceAlt, required this.border, required this.text, required this.textDim, required this.inverse, required this.onInverse});
}

const Palette darkPalette = Palette(
  background: Color(0xFF0B0B0B), surface: Color(0xFF141414), surfaceAlt: Color(0xFF1C1C1C), border: Color(0xFF2E2E2E),
  text: Color(0xFFF2F2F2), textDim: Color(0xFF8C8C8C), inverse: Color(0xFFF2F2F2), onInverse: Color(0xFF0B0B0B),
);
const Palette lightPalette = Palette(
  background: Color(0xFFFFFFFF), surface: Color(0xFFF6F6F6), surfaceAlt: Color(0xFFECECEC), border: Color(0xFFD4D4D4),
  text: Color(0xFF0B0B0B), textDim: Color(0xFF6B6B6B), inverse: Color(0xFF0B0B0B), onInverse: Color(0xFFFFFFFF),
);

// The only colors in the whole app.
const Color warnRed = Color(0xFFE5484D);
const Color infoBlue = Color(0xFF3E8BFF);
const Color okGreen = Color(0xFF30A46C);
const Color visionPurple = Color(0xFF8E4EC6);
const Color cautionAmber = Color(0xFFF5A524);

const String monoFont = 'monospace';

Palette paletteOf(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? darkPalette : lightPalette;

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? darkPalette : lightPalette;
  final scheme = ColorScheme(
    brightness: brightness, primary: p.inverse, onPrimary: p.onInverse, secondary: p.inverse, onSecondary: p.onInverse,
    error: warnRed, onError: Colors.white, surface: p.surface, onSurface: p.text,
  );
  return ThemeData(
    useMaterial3: true, colorScheme: scheme, scaffoldBackgroundColor: p.background, canvasColor: p.background, dividerColor: p.border,
    fontFamily: 'Inter', fontFamilyFallback: const ['SF Pro Text', 'Segoe UI', 'Roboto', 'Helvetica', 'Arial'],
    textTheme: Typography.material2021().black.apply(bodyColor: p.text, displayColor: p.text),
    dialogTheme: DialogThemeData(backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.border))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: p.surface, hintStyle: TextStyle(color: p.textDim),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: p.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: p.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: p.inverse, width: 1.2)),
    ),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: p.inverse, borderRadius: BorderRadius.circular(6)), textStyle: TextStyle(color: p.onInverse, fontSize: 12)),
    scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(p.border)),
  );
}
