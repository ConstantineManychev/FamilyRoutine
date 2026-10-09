import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';

mixin GeoTreeState<T extends ConsumerStatefulWidget> on ConsumerState<T>
{
  List<CountryDto> countries = const [];
  final Map<String, List<CityDto>> citiesCache = {};
  final Map<String, List<StreetDto>> streetsCache = {};

  String? expandedCountryId;
  String? expandedCityId;
  Object? loadError;
  bool isLoading = true;

  @override
  void initState()
  {
    super.initState();
    loadCountries();
  }

  Future<void> loadCountries() async
  {
    setState(()
    {
      isLoading = true;
      loadError = null;
    });

    try
    {
      final result = await ref.read(apiProv).getCountries();
      if (mounted)
      {
        setState(() => countries = result);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => loadError = aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> loadCities(String aCountryId) async
  {
    try
    {
      final cities = await ref.read(apiProv).getCities(aCountryId);
      if (mounted)
      {
        setState(()
        {
          citiesCache[aCountryId] = cities;
          expandedCountryId = aCountryId;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  Future<void> loadStreets(String aCityId) async
  {
    try
    {
      final streets = await ref.read(apiProv).getStreets(aCityId);
      if (mounted)
      {
        setState(()
        {
          streetsCache[aCityId] = streets;
          expandedCityId = aCityId;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  void toggleCountry(String aCountryId)
  {
    if (expandedCountryId == aCountryId)
    {
      setState(()
      {
        expandedCountryId = null;
        expandedCityId = null;
      });
      return;
    }

    setState(() => expandedCityId = null);
    loadCities(aCountryId);
  }

  void toggleCity(String aCityId)
  {
    if (expandedCityId == aCityId)
    {
      setState(() => expandedCityId = null);
      return;
    }

    loadStreets(aCityId);
  }

  Future<bool> runGeoAction(Future<void> Function() aAction) async
  {
    try
    {
      await aAction();
      return true;
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
      return false;
    }
  }

  Future<String?> askName({required String aTitle, required String aLabel, String? aInitial}) async
  {
    return showDialog<String>(
      context: context,
      builder: (_) => GeoNameDialog(title: aTitle, label: aLabel, initialValue: aInitial),
    );
  }

  Widget buildTree({required Widget Function(CountryDto) aCountryBody})
  {
    if (isLoading)
    {
      return const Center(child: CircularProgressIndicator());
    }

    if (loadError != null)
    {
      return ErrorRetry(error: loadError!, onRetry: loadCountries);
    }

    return ListView.builder(
      itemCount: countries.length,
      itemBuilder: (_, aIndex)
      {
        final country = countries[aIndex];
        final isExpanded = expandedCountryId == country.id;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              ListTile(
                title: Text(country.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                trailing: Icon(isExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown),
                onTap: () => toggleCountry(country.id),
                tileColor: isExpanded ? Colors.blue.shade50 : null,
              ),
              if (isExpanded) Padding(padding: const EdgeInsets.all(16), child: aCountryBody(country)),
            ],
          ),
        );
      },
    );
  }

  Widget buildEditActions({
    required bool aIsEditable,
    required VoidCallback aOnEdit,
    required VoidCallback aOnDelete,
  })
  {
    if (!aIsEditable)
    {
      return Tooltip(
        message: 'geo.read_only'.tr(),
        child: const Icon(LucideIcons.lock, size: 16, color: Colors.grey),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'common.edit'.tr(),
          icon: const Icon(LucideIcons.edit, size: 18),
          onPressed: aOnEdit,
        ),
        IconButton(
          tooltip: 'common.delete'.tr(),
          icon: const Icon(LucideIcons.trash, size: 18, color: Colors.red),
          onPressed: aOnDelete,
        ),
      ],
    );
  }
}

class GeoNameDialog extends StatefulWidget
{
  final String title;
  final String label;
  final String? initialValue;

  const GeoNameDialog({super.key, required this.title, required this.label, this.initialValue});

  @override
  State<GeoNameDialog> createState() => _GeoNameDialogState();
}

class _GeoNameDialogState extends State<GeoNameDialog>
{
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialValue);

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    final isEmpty = _ctrl.text.trim().isEmpty;

    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 100,
        decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: isEmpty ? null : () => Navigator.of(aContext).pop(_ctrl.text.trim()),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}
