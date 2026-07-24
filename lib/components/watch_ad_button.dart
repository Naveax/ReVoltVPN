import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/ad_manager.dart';

/// WatchAdButton is a voluntary option allowing the user to watch a rewarded video ad
/// and extend their active VPN tunnel session by 30 minutes as a reward.
class WatchAdButton extends StatelessWidget {
  const WatchAdButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final adWatched = await context.read<AdManager>().showAd('bonus_ad');
          if (!adWatched || !context.mounted) return;

          // The actual session extension happens server-side via AdMob SSV.
          // addBonusTime() syncs the new limits from the server.
          final synced = await context.read<SessionTimer>().addBonusTime();
          if (!context.mounted) return;

          if (synced) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  '+30 minutes added!',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                backgroundColor: const Color(0xFF006064),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not confirm bonus. Please check your connection.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                backgroundColor: Color(0xFF5D4037),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 3),
              ),
            );
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: [Color(0x1A00E5FF), Color(0x0D00E5FF)],
            ),
            border: Border.all(
              color: const Color.fromRGBO(0, 229, 255, 0.25),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('❤️', style: TextStyle(fontSize: 14)),
              SizedBox(width: 6),
              Text(
                'Support +30m',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF00E5FF),
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
