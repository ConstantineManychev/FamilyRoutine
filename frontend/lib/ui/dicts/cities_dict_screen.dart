import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import 'geo_tree.dart';

class CitiesDictScreen extends ConsumerStatefulWidget
{
  const CitiesDictScreen({super.key});

  @override
  ConsumerState<CitiesDictScreen> createState() => _CitiesDictScreenState();
}

class _CitiesDictScreenState extends ConsumerState<CitiesDictScreen> with GeoTreeState<CitiesDictScreen>
{
  Future<void> _addCity(CountryDto aCountry) async
  {
    final name = await askName(aTitle: 'geo.add_city'.tr(), aLabel: 'geo.city_name'.tr());
    if (name == null)
    {
      return;
    }

    if (await runGeoAction(() => ref.read(apiProv).createCity(aCountry.id, name)))
    {
      await loadCities(aCountry.id);
    }
  }

  Future<void> _editCity(CityDto aCity) async
  {
    final name = await askName(aTitle: 'geo.edit_city'.tr(), aLabel: 'geo.city_name'.tr(), aInitial: aCity.name);
    if (name == null || name == aCity.name)
    {
      return;
    }

    if (await runGeoAction(() => ref.read(apiProv).updateCity(aCity.id, name)))
    {
      await loadCities(aCity.countryId);
    }
  }

  Future<void> _deleteCity(CityDto aCity) async
  {
    final isConfirmed = await confirmAction(context, aTitle: aCity.name, aMessage: 'common.delete_confirm'.tr());
    if (!isConfirmed)
    {
      return;
    }

    if (await runGeoAction(() => ref.read(apiProv).deleteCity(aCity.id)))
    {
      await loadCities(aCity.countryId);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(title: 'geo.cities_dict'.tr()),
          const SizedBox(height: 24),
          Expanded(child: buildTree(aCountryBody: _buildCities)),
        ],
      ),
    );
  }

  Widget _buildCities(CountryDto aCountry)
  {
    final cities = citiesCache[aCountry.id] ?? const <CityDto>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _addCity(aCountry),
            icon: const Icon(AppIcons.plus, size: 18),
            label: Text('geo.add_city'.tr()),
          ),
        ),
        if (cities.isEmpty) Text('geo.no_cities'.tr(), style: const TextStyle(fontStyle: FontStyle.italic)),
        for (final city in cities)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                ListTile(
                  title: Text(city.name),
                  onTap: () => toggleCity(city.id),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildEditActions(
                        aIsEditable: city.isEditable,
                        aOnEdit: () => _editCity(city),
                        aOnDelete: () => _deleteCity(city),
                      ),
                      Icon(expandedCityId == city.id ? AppIcons.chevronUp : AppIcons.chevronDown),
                    ],
                  ),
                ),
                if (expandedCityId == city.id) _buildStreets(city.id),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStreets(String aCityId)
  {
    final streets = streetsCache[aCityId] ?? const <StreetDto>[];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Colors.grey.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('geo.streets_in_city'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          if (streets.isEmpty)
            Text('geo.no_streets'.tr(), style: const TextStyle(fontStyle: FontStyle.italic))
          else
            for (final street in streets)
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(street.name)),
        ],
      ),
    );
  }
}
