import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/ad_manager.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/session_timer.dart';

class SupportButton extends StatefulWidget {
  const SupportButton({super.key});

  @override
  State<SupportButton> createState() => _SupportButtonState();
}

class _SupportButtonState extends State<SupportButton> {
  bool _busy = false;

  Future<void> _handleTap() async {
    if (_busy || !AdManager.adsEnabled) return;

    final ad = context.read<AdManager>();
    final timer = context.read<SessionTimer>();

    if (!timer.isRunning && !timer.hasSyncedOnce) return;

    setState(() => _busy = true);
    try {
      await ad.showAd('support');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionTimer>(
      builder: (context, timer, _) {
        if (!AdManager.adsEnabled ||
            (!timer.isRunning && !timer.hasSyncedOnce)) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: _handleTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.glassBg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppColors.accent.withAlpha(100),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.favorite_border,
                  color: AppColors.accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accent,
                        ),
                      )
                    : const Text(
                        'Support us — 30 min!',
                        style: TextStyle(
                          color: AppColors.textWhite,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}
