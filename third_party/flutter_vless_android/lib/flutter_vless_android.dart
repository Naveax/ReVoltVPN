// Copyright (c) 2024-2026 13FOX Studio / tfox.dev.
// SPDX-License-Identifier: MIT

import 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart';

class FlutterVlessAndroid extends VlessMethodChannelAdapter {
  static void registerWith() {
    VlessPlatform.instance = FlutterVlessAndroid();
  }
}
