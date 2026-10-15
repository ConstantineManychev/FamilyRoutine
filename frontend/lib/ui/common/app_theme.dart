import 'package:flutter/material.dart';

enum AppThemeKind
{
  system,
  light,
  dark,
  violet;

  static AppThemeKind parse(String? aValue)
  {
    for (final kind in AppThemeKind.values)
    {
      if (kind.name == aValue)
      {
        return kind;
      }
    }
    return AppThemeKind.system;
  }
}

@immutable
class AppPalette extends ThemeExtension<AppPalette>
{
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkMuted;
  final Color border;
  final Color surfaceMuted;
  final Color grid;
  final Color baseline;
  final Color income;
  final Color expense;
  final Color positive;
  final Color warning;
  final Color danger;
  final Color hover;
  final Color surface;
  final List<Color> series;
  final Color seriesOther;

  const AppPalette({
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.border,
    required this.surfaceMuted,
    required this.grid,
    required this.baseline,
    required this.income,
    required this.expense,
    required this.positive,
    required this.warning,
    required this.danger,
    required this.hover,
    required this.surface,
    required this.series,
    required this.seriesOther,
  });

  static const List<Color> _lightSeries = [
    Color(0xFF2A78D6),
    Color(0xFFEB6834),
    Color(0xFF1BAF7A),
    Color(0xFFEDA100),
    Color(0xFFE87BA4),
    Color(0xFF008300),
    Color(0xFF6250D6),
    Color(0xFFE34948),
  ];

  static const List<Color> _darkSeries = [
    Color(0xFF3987E5),
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
    Color(0xFFD55181),
    Color(0xFF008300),
    Color(0xFF9085E9),
    Color(0xFFE66767),
  ];

  static const AppPalette light = AppPalette(
    inkPrimary: Color(0xFF0E1116),
    inkSecondary: Color(0xFF3F4652),
    inkMuted: Color(0xFF656C78),
    border: Color(0xFFE2E5EA),
    surfaceMuted: Color(0xFFF1F3F6),
    grid: Color(0xFFE6E8EC),
    baseline: Color(0xFFC3C7CF),
    income: Color(0xFF2A78D6),
    expense: Color(0xFFE34948),
    positive: Color(0xFF0B7A2F),
    warning: Color(0xFFA14A00),
    danger: Color(0xFFC62828),
    hover: Color(0x0F0E1116),
    surface: Color(0xFFFFFFFF),
    series: _lightSeries,
    seriesOther: Color(0xFF898781),
  );

  static const AppPalette dark = AppPalette(
    inkPrimary: Color(0xFFF2F3F5),
    inkSecondary: Color(0xFFC9CDD5),
    inkMuted: Color(0xFF9EA4AF),
    border: Color(0xFF2E323B),
    surfaceMuted: Color(0xFF23262E),
    grid: Color(0xFF2C2F36),
    baseline: Color(0xFF454A55),
    income: Color(0xFF3987E5),
    expense: Color(0xFFE66767),
    positive: Color(0xFF4CC46B),
    warning: Color(0xFFF2A54A),
    danger: Color(0xFFFF6B6B),
    hover: Color(0x14FFFFFF),
    surface: Color(0xFF17191E),
    series: _darkSeries,
    seriesOther: Color(0xFF8E939D),
  );

  static const AppPalette violet = AppPalette(
    inkPrimary: Color(0xFFF6F3FF),
    inkSecondary: Color(0xFFD5CDF2),
    inkMuted: Color(0xFFA99FD0),
    border: Color(0xFF3A2E5E),
    surfaceMuted: Color(0xFF2A2047),
    grid: Color(0xFF30264F),
    baseline: Color(0xFF4D4175),
    income: Color(0xFF3987E5),
    expense: Color(0xFFE66767),
    positive: Color(0xFF55CF7A),
    warning: Color(0xFFF5AE55),
    danger: Color(0xFFFF7575),
    hover: Color(0x14FFFFFF),
    surface: Color(0xFF1C1530),
    series: _darkSeries,
    seriesOther: Color(0xFF9A91BF),
  );

  Color seriesAt(int aSlot) => aSlot >= 0 && aSlot < series.length ? series[aSlot] : seriesOther;

  @override
  AppPalette copyWith({Color? inkPrimary, Color? inkSecondary, Color? inkMuted})
  {
    return AppPalette(
      inkPrimary: inkPrimary ?? this.inkPrimary,
      inkSecondary: inkSecondary ?? this.inkSecondary,
      inkMuted: inkMuted ?? this.inkMuted,
      border: border,
      surfaceMuted: surfaceMuted,
      grid: grid,
      baseline: baseline,
      income: income,
      expense: expense,
      positive: positive,
      warning: warning,
      danger: danger,
      hover: hover,
      surface: surface,
      series: series,
      seriesOther: seriesOther,
    );
  }

  @override
  AppPalette lerp(AppPalette? aOther, double aT)
  {
    if (aOther == null)
    {
      return this;
    }
    Color mix(Color aFrom, Color aTo) => Color.lerp(aFrom, aTo, aT) ?? aTo;
    return AppPalette(
      inkPrimary: mix(inkPrimary, aOther.inkPrimary),
      inkSecondary: mix(inkSecondary, aOther.inkSecondary),
      inkMuted: mix(inkMuted, aOther.inkMuted),
      border: mix(border, aOther.border),
      surfaceMuted: mix(surfaceMuted, aOther.surfaceMuted),
      grid: mix(grid, aOther.grid),
      baseline: mix(baseline, aOther.baseline),
      income: mix(income, aOther.income),
      expense: mix(expense, aOther.expense),
      positive: mix(positive, aOther.positive),
      warning: mix(warning, aOther.warning),
      danger: mix(danger, aOther.danger),
      hover: mix(hover, aOther.hover),
      surface: mix(surface, aOther.surface),
      series: [for (var i = 0; i < series.length; i++) mix(series[i], aOther.series[i])],
      seriesOther: mix(seriesOther, aOther.seriesOther),
    );
  }
}

extension AppPaletteContext on BuildContext
{
  AppPalette get palette => Theme.of(this).extension<AppPalette>() ?? AppPalette.light;

  ColorScheme get colors => Theme.of(this).colorScheme;
}

class _ThemeSpec
{
  final Brightness brightness;
  final AppPalette palette;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color background;
  final Color surface;
  final Color surfaceHigh;

  const _ThemeSpec({
    required this.brightness,
    required this.palette,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
  });
}

const _ThemeSpec _lightSpec = _ThemeSpec(
  brightness: Brightness.light,
  palette: AppPalette.light,
  primary: Color(0xFF1F5FD6),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE3ECFD),
  onPrimaryContainer: Color(0xFF0B3A8C),
  background: Color(0xFFF5F6F8),
  surface: Color(0xFFFFFFFF),
  surfaceHigh: Color(0xFFFFFFFF),
);

const _ThemeSpec _darkSpec = _ThemeSpec(
  brightness: Brightness.dark,
  palette: AppPalette.dark,
  primary: Color(0xFF8DB6FF),
  onPrimary: Color(0xFF06204D),
  primaryContainer: Color(0xFF1C3360),
  onPrimaryContainer: Color(0xFFDCE7FF),
  background: Color(0xFF0E0F12),
  surface: Color(0xFF17191E),
  surfaceHigh: Color(0xFF1F2228),
);

const _ThemeSpec _violetSpec = _ThemeSpec(
  brightness: Brightness.dark,
  palette: AppPalette.violet,
  primary: Color(0xFFC3B1FF),
  onPrimary: Color(0xFF2A1468),
  primaryContainer: Color(0xFF4A3592),
  onPrimaryContainer: Color(0xFFEDE6FF),
  background: Color(0xFF120D22),
  surface: Color(0xFF1C1530),
  surfaceHigh: Color(0xFF251C3E),
);

ThemeData _buildTheme(_ThemeSpec aSpec)
{
  final palette = aSpec.palette;
  final scheme = ColorScheme.fromSeed(seedColor: aSpec.primary, brightness: aSpec.brightness).copyWith(
    primary: aSpec.primary,
    onPrimary: aSpec.onPrimary,
    primaryContainer: aSpec.primaryContainer,
    onPrimaryContainer: aSpec.onPrimaryContainer,
    secondaryContainer: aSpec.primaryContainer,
    onSecondaryContainer: aSpec.onPrimaryContainer,
    surface: aSpec.surface,
    onSurface: palette.inkPrimary,
    onSurfaceVariant: palette.inkSecondary,
    surfaceContainerLowest: aSpec.background,
    surfaceContainerLow: aSpec.surface,
    surfaceContainer: aSpec.surface,
    surfaceContainerHigh: aSpec.surfaceHigh,
    surfaceContainerHighest: palette.surfaceMuted,
    outline: palette.inkMuted,
    outlineVariant: palette.border,
    error: palette.danger,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: palette.border));

  return ThemeData(
    useMaterial3: true,
    brightness: aSpec.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: aSpec.background,
    canvasColor: aSpec.surface,
    dividerColor: palette.border,
    hoverColor: palette.hover,
    extensions: [palette],
    appBarTheme: AppBarTheme(
      backgroundColor: aSpec.background,
      foregroundColor: palette.inkPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(color: aSpec.surface, surfaceTintColor: Colors.transparent, elevation: 0, shape: shape),
    dialogTheme: DialogThemeData(backgroundColor: aSpec.surfaceHigh, surfaceTintColor: Colors.transparent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: aSpec.surfaceHigh, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: aSpec.surfaceHigh, surfaceTintColor: Colors.transparent),
    menuTheme: MenuThemeData(
      style: MenuStyle(backgroundColor: WidgetStatePropertyAll(aSpec.surfaceHigh)),
    ),
    dividerTheme: DividerThemeData(color: palette.border, space: 1),
    listTileTheme: ListTileThemeData(iconColor: palette.inkSecondary, textColor: palette.inkPrimary),
    iconTheme: IconThemeData(color: palette.inkSecondary),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: TextStyle(color: palette.inkSecondary),
      hintStyle: TextStyle(color: palette.inkMuted),
      helperStyle: TextStyle(color: palette.inkMuted),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: palette.inkMuted)),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: palette.inkPrimary,
      unselectedLabelColor: palette.inkMuted,
      indicatorColor: aSpec.primary,
      dividerColor: palette.border,
      labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

final ThemeData lightTheme = _buildTheme(_lightSpec);
final ThemeData darkTheme = _buildTheme(_darkSpec);
final ThemeData violetTheme = _buildTheme(_violetSpec);
