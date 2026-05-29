import 'package:flutter/material.dart';

/// Header displays the Paladin brand logo, title, and subtitle.
/// 
/// It represents the top branding portion of the main dashboard and is designed
/// with clean proportions, consistent typography, and a modern cyberpunk-inspired color scheme.
class Header extends StatelessWidget {
  const Header({super.key});

  // Cyber-paladin cyan glow accent color used as a fallback for the shield icon
  static const Color _cyanGlow = Color(0xFF00E5FF);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Brand logo image with a fallback Icon in case the asset is missing
        Image.asset(
          'assets/logo.png',
          width: 120, // Enlarged logo to stand out visually
          height: 120,
          errorBuilder: (context, error, stackTrace) => const Icon(
            Icons.shield,
            size: 120,
            color: _cyanGlow,
          ),
        ),
        const SizedBox(height: 8), // Standard padding between the logo and the title
        
        // Brand primary name
        const Text(
          'Paladin',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 8,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 2), // Close spacing for secondary information
        
        // Brand secondary label / purpose
        const Text(
          'SECURE TUNNEL',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 4,
            color: Color(0xAA4A5568), // Semi-transparent slate gray
          ),
        ),
      ],
    );
  }
}
