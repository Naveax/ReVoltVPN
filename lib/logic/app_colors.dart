import 'package:flutter/material.dart';

// =============================================================================
//  app_colors.dart — Single source of truth for every color in ReVoltVPN
//  ─────────────────────────────────────────────────────────────────────────────
//  Import this file and reference AppColors.* instead of hardcoding hex values
//  or Color.fromRGBO() calls anywhere else in the app.
// =============================================================================

abstract final class AppColors {
  AppColors._();

  // ── Primary: Cyan ──────────────────────────────────────────────────────────
  static const Color cyan       = Color(0xFF00E5FF);
  static const Color cyan15     = Color(0x2600E5FF); // 15 % opacity
  static const Color cyan25     = Color(0x4000E5FF); // 25 % opacity
  static const Color cyan50     = Color(0x8000E5FF); // 50 % opacity
  static const Color cyan60     = Color(0x9900E5FF); // 60 % opacity
  static const Color cyan70     = Color(0xB300E5FF); // 70 % opacity
  static const Color cyan05     = Color(0x0D00E5FF); //  5 % opacity
  static const Color cyanGlow   = Color(0x8800E5FF); // glowing border

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
  static const Color slateAA    = Color(0xAA4A5568); // ~67 % (legacy usage)

  // ── Text ───────────────────────────────────────────────────────────────────
  static const Color textWhite  = Colors.white;
  static const Color textDim    = Colors.white54;
  static const Color textWhite80 = Color(0xCCFFFFFF); // 80 % white
  static const Color textMuted   = Color(0xFFA0AEC0); // dialog body text

  // ── Semantic ───────────────────────────────────────────────────────────────
  static const Color green      = Color(0xFF00E676);
  static const Color green50    = Color(0x8000E676); // 50 % opacity
  static const Color red        = Color(0xFFEF5350);

  // ── Glass / Borders ────────────────────────────────────────────────────────
  static const Color glassBg    = Color(0x22FFFFFF); // subtle glass background
  static const Color glassBorder = Color(0x33FFFFFF); // muted translucent border

  // ── Intro screen snackbars ─────────────────────────────────────────────────
  static const Color snackSuccess = Color(0xFF006064);
  static const Color snackError   = Color(0xFF5D4037);

  // ═══════════════════════════════════════════════════════════════════════════
  // FUTURE — Yellow palette (not yet wired into the UI)
  // ═══════════════════════════════════════════════════════════════════════════
  static const Color yellow        = Color(0xFFFFD600);
  static const Color yellowDark    = Color(0xFFFFAB00);
  static const Color yellowLight   = Color(0xFFFFFF00);
  static const Color yellowFaded   = Color(0x1AFFD600);
  static const Color yellowAmber   = Color(0xFFFFC107);
  static const Color yellowMustard = Color(0xFFC6A700);

  // ═══════════════════════════════════════════════════════════════════════════
  // FUTURE — Black palette (not yet wired into the UI)
  // ═══════════════════════════════════════════════════════════════════════════
  static const Color black        = Color(0xFF000000);
  static const Color blackOff     = Color(0xFF0A0A0A);
  static const Color blackFaded   = Color(0xAA000000);
  static const Color blackWarm    = Color(0xFF121212);
  static const Color blackCharcoal = Color(0xFF1A1A1A);
}
