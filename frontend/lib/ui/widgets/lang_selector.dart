import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../common/app_icons.dart';
import '../common/app_theme.dart';

const Map<String, String> langNames = {
  'ru': 'Русский',
  'en': 'English',
  'fr': 'Français',
  'de': 'Deutsch',
  'zh': '中文',
  'ja': '日本語',
};

class LangSelector extends StatelessWidget
{
  const LangSelector({super.key});

  @override
  Widget build(BuildContext aContext)
  {
    final curLocale = aContext.locale;

    return PopupMenuButton<Locale>(
      initialValue: curLocale,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: aContext.colors.surface,
      elevation: 4,
      onSelected: aContext.setLocale,
      itemBuilder: (aMenuContext) => aMenuContext.supportedLocales.map((aLocale)
      {
        final isSelected = curLocale == aLocale;
        return PopupMenuItem<Locale>(
          value: aLocale,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                langNames[aLocale.languageCode] ?? aLocale.languageCode.toUpperCase(),
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? aContext.colors.primary : aContext.palette.inkSecondary,
                ),
              ),
              if (isSelected) Icon(AppIcons.check, size: 16, color: aContext.colors.primary),
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: aContext.colors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: aContext.palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.globe, size: 18, color: aContext.palette.inkSecondary),
            const SizedBox(width: 8),
            Text(
              langNames[curLocale.languageCode] ?? curLocale.languageCode.toUpperCase(),
              style: TextStyle(fontWeight: FontWeight.w600, color: aContext.palette.inkSecondary),
            ),
            const SizedBox(width: 6),
            Icon(AppIcons.chevronDown, size: 16, color: aContext.palette.inkMuted),
          ],
        ),
      ),
    );
  }
}
