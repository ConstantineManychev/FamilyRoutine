import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../dicts/scope_widgets.dart';

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

    final parts = [addr.label ?? '${'places.house'.tr()} ${addr.houseNum}'];
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

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'sidebar.places'.tr(),
            actions: [
              ElevatedButton.icon(
                onPressed: () => aContext.go('/app/places/new'),
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('places.add'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: placesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(placesProv)),
              data: (aPlaces) => aPlaces.isEmpty
                  ? Center(child: Text('common.no_data'.tr()))
                  : ListView.builder(
                      itemCount: aPlaces.length,
                      itemBuilder: (_, aIndex)
                      {
                        final place = aPlaces[aIndex];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            leading: const Icon(AppIcons.mapPin, color: Colors.blue),
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
                            onTap: () => aContext.go('/app/places/${place.id}'),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
