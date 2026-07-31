// =============================================================================
//  clock_display.dart — EDUCATIONAL REFERENCE (not used in production)
//  =============================================================================
//
//  This widget was the original combined timer + speed + syncing display.
//  It was replaced by the separate TimerBox and SpeedBox widgets in the
//  Reality-era UI refactor.
//
//  What's worth studying here:
//
//  1. TEXT GLOW EFFECT — the yellow glow around the countdown timer:
//     ```
//     shadows: [Shadow(color: AppColors.accent50, blurRadius: 16)]
//     ```
//     This exact effect was ported to timer_box.dart and is what gives
//     the countdown its signature pulsing-yellow look.
//
//  2. SYNCING PLACEHOLDER — conditional spinner + label when the first
//     server poll hasn't returned yet.  Shows "Syncing…" with a small
//     CircularProgressIndicator instead of flashing 00:00:00.
//
//  3. COMBINED DISPLAY — clock + speed stacked in a Column inside a
//     fixed 200×200 SizedBox.  The modern UI split these into separate
//     boxes for the stacked layout, but the stacking approach here is
//     a good reference for compact combined displays.
//
//  Kept in the repo for reference.  Safe to delete if you're pruning.
// =============================================================================

// import 'package:flutter/material.dart';
// import 'package:provider/provider.dart';
// import 'package:revoltvpn/logic/app_colors.dart';
// import 'package:revoltvpn/logic/session_timer.dart';

// class ClockDisplay extends StatelessWidget {
//   const ClockDisplay({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Consumer<SessionTimer>(
//       builder: (context, timer, _) {
//         final bool showSyncing = !timer.hasSyncedOnce;

//         return SizedBox(
//           width: 200,
//           height: 200,
//           child: Stack(
//             alignment: Alignment.center,
//             children: [
//               Column(
//                 mainAxisSize: MainAxisSize.min,
//                 children: [
//                   if (showSyncing) ...[
//                     const SizedBox(
//                       width: 32,
//                       height: 32,
//                       child: CircularProgressIndicator(
//                         strokeWidth: 2,
//                         color: AppColors.accent50,
//                       ),
//                     ),
//                     const SizedBox(height: 10),
//                     const Text(
//                       'Syncing…',
//                       style: TextStyle(
//                         fontSize: 16,
//                         fontWeight: FontWeight.w600,
//                         color: AppColors.accent60,
//                         letterSpacing: 1.5,
//                       ),
//                     ),
//                   ] else ...[
//                     Text(
//                       timer.formatted,
//                       style: const TextStyle(
//                         fontSize: 40,
//                         fontWeight: FontWeight.w800,
//                         color: AppColors.textWhite,
//                         letterSpacing: 2,
//                         shadows: [
//                           Shadow(
//                             color: AppColors.accent50,
//                             blurRadius: 16,
//                           ),
//                         ],
//                       ),
//                     ),
//                     const SizedBox(height: 6),
//                     Row(
//                       mainAxisSize: MainAxisSize.min,
//                       children: [
//                         const Icon(Icons.speed, color: AppColors.textDim, size: 14),
//                         const SizedBox(width: 4),
//                         Text(
//                           timer.currentSpeedKBps > 0.5
//                               ? '${timer.currentSpeedKBps.toStringAsFixed(1)} KB/s'
//                               : 'Idle',
//                           style: const TextStyle(
//                             fontSize: 12,
//                             color: AppColors.textDim,
//                             fontWeight: FontWeight.w500,
//                           ),
//                         ),
//                       ],
//                     ),
//                   ],
//                 ],
//               ),
//             ],
//           ),
//         );
//       },
//     );
//   }
// }
