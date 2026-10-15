import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'geo_tree.dart';
import '../common/app_theme.dart';

class StreetsDictScreen extends ConsumerStatefulWidget
{
  const StreetsDictScreen({super.key});

  @override
  ConsumerState<StreetsDictScreen> createState() => _StreetsDictScreenState();
}

class _StreetsDictScreenState extends ConsumerState<StreetsDictScreen> with GeoTreeState<StreetsDictScreen>
{
  Future<void> _addStreet(CityDto aCity) async
  {
    final name = await askName(aTitle: 'geo.add_street'.tr(), aLabel: 'geo.street_name'.tr());
    if (name == null)
    {
      return;
    }

    if (await runGeoAction(() => ref.read(apiProv).createStreet(aCity.id, name)))
    {
      await loadStreets(aCity.id);
    }
  }

  Future<void> _editStreet(StreetDto aStreet) async
  {
    final name = await askName(
      aTitle: 'geo.edit_street'.tr(),
      aLabel: 'geo.street_name'.tr(),
      aInitial: aStreet.name,
    );
    if (name == null || name == aStreet.name)
    {
      return;
    }

    if (await runGeoAction(() => ref.read(apiProv).updateStreet(aStreet.id, name)))
    {
      await loadStreets(aStreet.cityId);
    }
  }

  Future<void> _deleteStreet(StreetDto aStreet) async
  {
    final isConfirmed = await confirmAction(context, aTitle: aStreet.name, aMessage: 'common.delete_confirm'.tr());
    if (!isConfirmed)
    {
      return;
    }

    if (await runGeoAction(() => ref.read(apiProv).deleteStreet(aStreet.id)))
    {
      await loadStreets(aStreet.cityId);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    return ListPage(
      title: 'geo.streets_dict'.tr(),
      onSearch: (aQuery) => setState(() => geoQuery = aQuery.trim().toLowerCase()),
      child: buildTree(aCountryBody: _buildCities),
    );
  }

  Widget _buildCities(CountryDto aCountry)
  {
    final cities = visibleCities(aCountry);

    if (cities.isEmpty)
    {
      return Text('geo.no_cities'.tr(), style: const TextStyle(fontStyle: FontStyle.italic));
    }

    return Column(
      children: [
        for (final city in cities)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              border: Border.all(color: context.palette.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                ListTile(
                  title: Text(city.name),
                  trailing: Icon(expandedCityId == city.id ? AppIcons.chevronUp : AppIcons.chevronDown),
                  onTap: () => toggleCity(city.id),
                  tileColor: expandedCityId == city.id ? context.palette.surfaceMuted : null,
                ),
                if (expandedCityId == city.id) _buildStreets(city),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStreets(CityDto aCity)
  {
    final streets = streetsCache[aCity.id] ?? const <StreetDto>[];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: context.palette.surfaceMuted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _addStreet(aCity),
              icon: const Icon(AppIcons.plus, size: 18),
              label: Text('geo.add_street'.tr()),
            ),
          ),
          if (streets.isEmpty) Text('geo.no_streets'.tr(), style: const TextStyle(fontStyle: FontStyle.italic)),
          for (final street in streets)
            ListTile(
              title: Text(street.name),
              trailing: buildEditActions(
                aIsEditable: street.isEditable,
                aOnEdit: () => _editStreet(street),
                aOnDelete: () => _deleteStreet(street),
              ),
            ),
        ],
      ),
    );
  }
}
