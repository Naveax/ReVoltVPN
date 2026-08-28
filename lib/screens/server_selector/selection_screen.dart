import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';
import 'package:revoltvpn/logic/server_list.dart';

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
          onPressed: () {
            HapticSettings.tap();
            Navigator.of(context).pop();
          },
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
            title: Text(
              server.name,
              style: TextStyle(
                color: isSelected ? AppColors.accent : AppColors.textWhite,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: isSelected
                ? const Icon(Icons.check, color: AppColors.accent)
                : null,
            onTap: () {
              HapticSettings.selection();
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
