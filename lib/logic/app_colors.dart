import 'package:flutter/material.dart';

// =============================================================================
//  app_colors.dart — Single source of truth for every color in ReVoltVPN
//  ─────────────────────────────────────────────────────────────────────────────
//  Import this file and reference AppColors.* instead of hardcoding hex values
//  or Color.fromRGBO() calls anywhere else in the app.
// =============================================================================

abstract final class AppColors {
  AppColors._();

  // ── Accent ────────────────────────────────────────────────────────────────
  static const Color accent     = Color(0xFFFFD600); // yellow
  static const Color accent50   = Color(0x80FFD600); // 50 % opacity
  static const Color accent60   = Color(0x99FFD600); // 60 % opacity
  static const Color accent70   = Color(0xB3FFD600); // 70 % opacity

  // ── Backgrounds ────────────────────────────────────────────────────────────
  static const Color bgDeep     = Color(0xFF0D1117); // intro / scaffold
  static const Color bgDark     = Color(0xFF1A202C); // button circle
  static const Color bgSurface  = Color(0xFF151C28); // colorScheme surface
  static const Color bgCard     = Color(0xFF1E2533); // bottom bar, snackbar
  static const Color bgOverlay  = Color(0xAA0D1117); // semi-transparent overlay

  // ── Slate / Gray ───────────────────────────────────────────────────────────
  static const Color slate      = Color(0xFF4A5568);
  static const Color slate15    = Color(0x264A5568); // 15 % opacity
  static const Color slate50    = Color(0x804A5568); // 50 % opacity
  static const Color slate70    = Color(0xB34A5568); // 70 % opacity

  // ── Text ───────────────────────────────────────────────────────────────────
  static const Color textWhite  = Colors.white;
  static const Color textDim    = Colors.white54;
  static const Color textMuted  = Color(0xFFA0AEC0); // dialog body text

  // ── Semantic ───────────────────────────────────────────────────────────────
  static const Color green      = Color(0xFF00E676);
  static const Color green50    = Color(0x8000E676); // 50 % opacity
  static const Color red        = Color(0xFFEF5350);

  // ── Glass / Borders ────────────────────────────────────────────────────────
  static const Color glassBg    = Color(0x22FFFFFF); // subtle glass background
  static const Color glassBorder = Color(0x33FFFFFF); // muted translucent border

}
