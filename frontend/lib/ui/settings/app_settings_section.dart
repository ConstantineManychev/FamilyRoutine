import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../widgets/lang_selector.dart';

const Map<AppThemeKind, IconData> _themeIcons = {
  AppThemeKind.system: AppIcons.sunMoon,
  AppThemeKind.light: AppIcons.sun,
  AppThemeKind.dark: AppIcons.moon,
  AppThemeKind.violet: AppIcons.palette,
};

class AppSettingsSection extends ConsumerWidget
{
  final bool isSignOutVisible;

  const AppSettingsSection({super.key, this.isSignOutVisible = true});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    final themeKind = aRef.watch(themeKindProv);
    final palette = aContext.palette;

    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('settings.title'.tr(), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: palette.inkPrimary)),
            const SizedBox(height: 16),
            Text('settings.theme'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkPrimary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in AppThemeKind.values)
                  ChoiceChip(
                    avatar: Icon(_themeIcons[kind], size: 16),
                    label: Text('settings.theme_${kind.name}'.tr()),
                    selected: themeKind == kind,
                    onSelected: (_) => aRef.read(themeKindProv.notifier).select(kind),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('settings.language'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkPrimary)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 260,
                child: DropdownButtonFormField<String>(
                  initialValue: langNames.containsKey(aContext.locale.languageCode) ? aContext.locale.languageCode : 'en',
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, prefixIcon: Icon(AppIcons.languages, size: 18)),
                  items: [
                    for (final entry in langNames.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                  ],
                  onChanged: (aCode)
                  {
                    if (aCode != null)
                    {
                      aContext.setLocale(Locale(aCode));
                    }
                  },
                ),
              ),
            ),
            if (isSignOutVisible) ...[
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: palette.danger),
                  onPressed: () => aRef.read(authProv.notifier).logout(),
                  icon: const Icon(AppIcons.logOut, size: 18),
                  label: Text('profile.sign_out'.tr()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
