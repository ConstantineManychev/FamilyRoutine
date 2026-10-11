import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../common/feedback.dart';
import 'ai_settings_section.dart';

class SettingsScreen extends StatelessWidget
{
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(title: 'settings.title'.tr()),
        const SizedBox(height: 24),
        const AiSettingsSection(),
      ],
    );
  }
}
