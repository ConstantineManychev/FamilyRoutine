import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../stock/stock_format.dart';

class StockSettingsSection extends ConsumerWidget
{
  const StockSettingsSection({super.key});

  Future<void> _select(BuildContext aContext, WidgetRef aRef, String? aFamilyId) async
  {
    try
    {
      await aRef.read(apiProv).saveStockSettings(aFamilyId);
      notifyStockChanged(aRef);
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final palette = aContext.palette;
    final settings = aRef.watch(stockSettingsProv);
    final Widget body = settings.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const LinearProgressIndicator(),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(stockSettingsProv)),
      data: (aSettings)
      {
        final active = aSettings.active.ref;
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 360,
            child: DropdownButtonFormField<String>(
              key: ValueKey('settings.stock.${active.familyId ?? 'personal'}'),
              initialValue: active.familyId ?? '',
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'settings.stock_default'.tr(),
                border: const OutlineInputBorder(),
                isDense: true,
                prefixIcon: const Icon(AppIcons.package, size: 18),
              ),
              items: [
                for (final store in aSettings.stores)
                  DropdownMenuItem(
                    value: store.ref.familyId ?? '',
                    child: Text(storeLabel(store.ref), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (aValue) => _select(aContext, aRef, aValue == null || aValue.isEmpty ? null : aValue),
            ),
          ),
        );
      },
    );

    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('settings.stock_title'.tr(), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: palette.inkPrimary)),
            const SizedBox(height: 6),
            Text('settings.stock_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}
