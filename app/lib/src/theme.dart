import 'package:flutter/material.dart';

/// Goober's "sunny boardwalk" palette and theme.
class GooberColors {
  static const sand = Color(0xFFFBF6EA); // sand paper — background
  static const ink = Color(0xFF123B45); // ocean-teal ink — text
  static const cartTeal = Color(0xFF17A88C); // golf-cart teal — primary actions
  static const marigold = Color(0xFFFFBB2E); // points / trophy
  static const coral = Color(0xFFFF6F5B); // accents
  static const sky = Color(0xFF8FD3E8); // maps
}

ThemeData buildGooberTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: GooberColors.cartTeal,
    primary: GooberColors.cartTeal,
    secondary: GooberColors.marigold,
    surface: GooberColors.sand,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: GooberColors.sand,
    appBarTheme: const AppBarTheme(
      backgroundColor: GooberColors.sand,
      foregroundColor: GooberColors.ink,
      elevation: 0,
      centerTitle: true,
    ),
    textTheme: Typography.blackMountainView.apply(
      bodyColor: GooberColors.ink,
      displayColor: GooberColors.ink,
    ),
  );
}
