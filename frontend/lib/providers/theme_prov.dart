import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/common/app_theme.dart';

const String _themePref = 'ui.theme';

class ThemeKindNotifier extends Notifier<AppThemeKind>
{
  @override
  AppThemeKind build()
  {
    _restore();
    return AppThemeKind.system;
  }

  Future<SharedPreferences?> _prefs() async
  {
    try
    {
      return await SharedPreferences.getInstance();
    }
    on Exception
    {
      return null;
    }
  }

  Future<void> _restore() async
  {
    final prefs = await _prefs();
    final stored = AppThemeKind.parse(prefs?.getString(_themePref));
    if (stored != state)
    {
      state = stored;
    }
  }

  Future<void> select(AppThemeKind aKind) async
  {
    state = aKind;
    final prefs = await _prefs();
    await prefs?.setString(_themePref, aKind.name);
  }
}

final NotifierProvider<ThemeKindNotifier, AppThemeKind> themeKindProv =
    NotifierProvider<ThemeKindNotifier, AppThemeKind>(ThemeKindNotifier.new);

class ThemeSetup
{
  final ThemeData light;
  final ThemeData dark;
  final ThemeMode mode;

  const ThemeSetup({required this.light, required this.dark, required this.mode});

  factory ThemeSetup.of(AppThemeKind aKind) => switch (aKind)
  {
    AppThemeKind.system => ThemeSetup(light: lightTheme, dark: darkTheme, mode: ThemeMode.system),
    AppThemeKind.light => ThemeSetup(light: lightTheme, dark: darkTheme, mode: ThemeMode.light),
    AppThemeKind.dark => ThemeSetup(light: lightTheme, dark: darkTheme, mode: ThemeMode.dark),
    AppThemeKind.violet => ThemeSetup(light: violetTheme, dark: violetTheme, mode: ThemeMode.dark),
  };
}
