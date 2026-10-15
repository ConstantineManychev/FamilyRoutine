import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../dicts/scope_widgets.dart';
import '../common/app_theme.dart';

final AutoDisposeFutureProvider<List<PlaceDto>> placesProv = FutureProvider.autoDispose<List<PlaceDto>>((aRef) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getPlaces();
});

class PlacesScreen extends ConsumerWidget
{
  const PlacesScreen({super.key});

  String _subtitle(PlaceDto aPlace)
  {
    final addr = aPlace.mainAddr;
    if (addr == null)
    {
      return 'places.no_address'.tr();
    }

    final parts = [addr.label ?? ''];
    if (addr.apt != null && addr.apt!.isNotEmpty)
    {
      parts.add('${'places.apt'.tr()} ${addr.apt}');
    }
    if (aPlace.addrs.length > 1)
    {
      parts.add('places.branch_count'.tr(args: ['${aPlace.addrs.length}']));
    }
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final placesAsync = aRef.watch(placesProv);

    return ListPage(
      title: 'sidebar.places'.tr(),
      onAdd: () => aContext.push('/app/places/new'),
      addTooltip: 'places.add'.tr(),
      builder: (_, aQuery) => placesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(placesProv)),
        data: (aPlaces)
        {
          final shown = aPlaces
              .where((aPlace) => aQuery.isEmpty || '${aPlace.name} ${_subtitle(aPlace)}'.toLowerCase().contains(aQuery))
              .toList();
          if (shown.isEmpty)
          {
            return Center(child: Text('common.no_data'.tr()));
          }
          return ListView.builder(
            key: const PageStorageKey('list.places'),
            padding: screenPadding(aContext),
            itemCount: shown.length,
            itemBuilder: (_, aIndex)
            {
              final place = shown[aIndex];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Icon(AppIcons.mapPin, color: aContext.colors.primary),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          place.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (place.familyName != null) ...[
                        const SizedBox(width: 8),
                        FamilyBadge(name: place.familyName!),
                      ],
                    ],
                  ),
                  subtitle: Text(_subtitle(place)),
                  trailing: const Icon(AppIcons.chevronRight),
                  onTap: () => aContext.push('/app/places/${place.id}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
