import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';

class LangSelector extends StatelessWidget {
  const LangSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final Map<String, String> langNames = {
      'ru': 'Русский',
      'en': 'English',
      'fr': 'Français',
      'de': 'Deutsch',
      'zh': '中文',
      'ja': '日本語',
    };

    final curLocale = context.locale;

    return PopupMenuButton<Locale>(
      initialValue: curLocale,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white,
      elevation: 4,
      onSelected: (Locale newLocale) {
        context.setLocale(newLocale);
      },
      itemBuilder: (BuildContext context) {
        return context.supportedLocales.map((Locale locale) {
          final code = locale.languageCode;
          final isSelected = curLocale == locale;
          
          return PopupMenuItem<Locale>(
            value: locale,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  langNames[code] ?? code.toUpperCase(),
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF374151),
                  ),
                ),
                if (isSelected) 
                  const Icon(LucideIcons.check, size: 16, color: Color(0xFF2563EB)),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.globe, size: 18, color: Color(0xFF4B5563)),
            const SizedBox(width: 8),
            Text(
              langNames[curLocale.languageCode] ?? curLocale.languageCode.toUpperCase(),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF4B5563),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(LucideIcons.chevronDown, size: 16, color: Color(0xFF9CA3AF)),
          ],
        ),
      ),
    );
  }
}