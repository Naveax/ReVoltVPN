import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/server_list.dart';

// ── lib/screens/server_selector/selection_screen.dart ──────────────────────
// Server picker — reads the server list from the ServerList provider.
// Each row shows a flag + city name.  Tapping a row persists the choice
// and pops back.  No latency measurement — the app runs inside a Reality
// tunnel and must not emit separate probe traffic.

class SelectionScreen extends StatelessWidget {
  const SelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final serverList = context.watch<ServerList>();

    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textWhite),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Select Server',
          style: TextStyle(
            color: AppColors.textWhite,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView.builder(
        itemCount: serverList.all.length,
        itemBuilder: (context, index) {
          final server = serverList.all[index];
          final isSelected = index == serverList.selectedIndex;

          return ListTile(
            leading: Image.asset(server.flagAsset, width: 28, height: 28),
            title: Text(server.name,
                style: TextStyle(
                  color: isSelected ? AppColors.accent : AppColors.textWhite,
                  fontWeight: FontWeight.w600,
                )),
            trailing: isSelected
                ? const Icon(Icons.check, color: AppColors.accent)
                : null,
            onTap: () {
              serverList.select(index);
              Navigator.of(context).pop();
            },
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          );
        },
      ),
    );
  }
}
