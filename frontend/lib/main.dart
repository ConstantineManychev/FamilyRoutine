import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'core/app_router.dart';
import 'core/device_tz.dart';
import 'providers/theme_prov.dart';
import 'ui/common/barcode_scanner.dart';

const List<Locale> supportedLocales = [
  Locale('ru'),
  Locale('en'),
  Locale('fr'),
  Locale('de'),
  Locale('zh'),
  Locale('ja'),
];

Future<void> main() async
{
  usePathUrlStrategy();
  final binding = WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(_lucideLicense);
  configureBarcodeScanner();
  Intl.systemLocale = Intl.canonicalizedLocale(binding.platformDispatcher.locale.toLanguageTag());
  await Future.wait([EasyLocalization.ensureInitialized(), detectDeviceTimeZone()]);

  runApp(
    ProviderScope(
      child: EasyLocalization(
        supportedLocales: supportedLocales,
        path: 'assets/i18n',
        fallbackLocale: const Locale('en'),
        useFallbackTranslations: true,
        child: const AppRoot(),
      ),
    ),
  );
}

Stream<LicenseEntry> _lucideLicense() async*
{
  final text = await rootBundle.loadString('assets/fonts/LICENSE-lucide.txt');
  yield LicenseEntryWithLineBreaks(const ['Lucide'], text);
}

class AppRoot extends ConsumerWidget
{
  const AppRoot({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    final themes = ThemeSetup.of(aRef.watch(themeKindProv));

    return MaterialApp.router(
      title: 'Family Routine',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: aContext.localizationDelegates,
      supportedLocales: aContext.supportedLocales,
      locale: aContext.locale,
      routerConfig: aRef.watch(routerProv),
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: themes.mode,
    );
  }
}
