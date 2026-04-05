import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class StreetsDictScreen extends ConsumerStatefulWidget {
  const StreetsDictScreen({super.key});

  @override
  ConsumerState<StreetsDictScreen> createState() => _StreetsDictScreenState();
}

class _StreetsDictScreenState extends ConsumerState<StreetsDictScreen> {
  List<CountryDto> _countries = [];
  Map<String, List<CityDto>> _citiesCache = {};
  Map<String, List<StreetDto>> _streetsCache = {};
  
  String? _expandedCountryId;
  String? _expandedCityId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCountries();
  }

  Future<void> _loadCountries() async {
    setState(() => _isLoading = true);
    try {
      _countries = await ref.read(apiProv).getCountries();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadCitiesForCountry(String countryId) async {
    final cities = await ref.read(apiProv).getCities(countryId);
    setState(() {
      _citiesCache[countryId] = cities;
      _expandedCountryId = countryId;
      _expandedCityId = null;
    });
  }

  Future<void> _loadStreetsForCity(String cityId) async {
    final streets = await ref.read(apiProv).getStreets(cityId);
    setState(() {
      _streetsCache[cityId] = streets;
      _expandedCityId = cityId;
    });
  }

  void _handleCountryTap(String countryId) {
    if (_expandedCountryId == countryId) {
      setState(() {
        _expandedCountryId = null;
        _expandedCityId = null;
      });
    } else {
      _loadCitiesForCountry(countryId);
    }
  }

  void _handleCityTap(String cityId) {
    if (_expandedCityId == cityId) {
      setState(() => _expandedCityId = null);
    } else {
      _loadStreetsForCity(cityId);
    }
  }

  Future<void> _showStreetDialog({StreetDto? street}) async {
    CountryDto? selectedCountry = _expandedCountryId != null 
        ? _countries.firstWhere((c) => c.id == _expandedCountryId)
        : null;
        
    CityDto? selectedCity = _expandedCityId != null && selectedCountry != null
        ? _citiesCache[selectedCountry!.id]?.firstWhere((c) => c.id == _expandedCityId)
        : null;

    final nameCtrl = TextEditingController(text: street?.name);
    final isEdit = street != null;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isBtnDisabled = nameCtrl.text.trim().isEmpty || selectedCity == null;
          final availableCities = selectedCountry != null ? _citiesCache[selectedCountry!.id] ?? [] : <CityDto>[];

          return AlertDialog(
            title: Text(isEdit ? 'geo.edit_street'.tr() : 'geo.add_street'.tr()),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<CountryDto>(
                  value: selectedCountry,
                  decoration: InputDecoration(labelText: 'geo.country'.tr(), border: const OutlineInputBorder()),
                  items: _countries.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
                  onChanged: isEdit ? null : (v) {
                    setDialogState(() {
                      selectedCountry = v;
                      selectedCity = null;
                    });
                    if (v != null) {
                      ref.read(apiProv).getCities(v.id).then((cities) {
                        setState(() => _citiesCache[v.id] = cities);
                        setDialogState(() {});
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<CityDto>(
                  value: selectedCity,
                  decoration: InputDecoration(labelText: 'geo.city'.tr(), border: const OutlineInputBorder()),
                  items: availableCities.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
                  onChanged: isEdit ? null : (v) => setDialogState(() => selectedCity = v),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: 'geo.street_name'.tr(), border: const OutlineInputBorder()),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('common.cancel'.tr())),
              ElevatedButton(
                onPressed: isBtnDisabled ? null : () async {
                  if (isEdit) {
                    await ref.read(apiProv).updateStreet(street.id, nameCtrl.text.trim());
                  } else {
                    await ref.read(apiProv).createStreet(selectedCity!.id, nameCtrl.text.trim());
                  }
                  Navigator.pop(ctx);
                  _loadStreetsForCity(selectedCity!.id);
                },
                child: Text('common.save'.tr()),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteStreet(StreetDto street) async {
    await ref.read(apiProv).deleteStreet(street.id);
    _loadStreetsForCity(street.cityId);
  }

  @override
  Widget build(BuildContext context) {
    context.locale;
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('geo.streets_dict'.tr(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: () => _showStreetDialog(),
                icon: const Icon(LucideIcons.plus, size: 18),
                label: Text('geo.add_street'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Expanded(
            child: ListView.builder(
              itemCount: _countries.length,
              itemBuilder: (context, index) {
                final country = _countries[index];
                final isCountryExpanded = _expandedCountryId == country.id;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(country.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        trailing: Icon(isCountryExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown),
                        onTap: () => _handleCountryTap(country.id),
                        tileColor: isCountryExpanded ? Colors.blue.shade50 : null,
                      ),
                      if (isCountryExpanded)
                        Container(
                          padding: const EdgeInsets.all(16),
                          color: Colors.white,
                          child: _buildCitiesList(country.id),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCitiesList(String countryId) {
    final cities = _citiesCache[countryId] ?? [];
    if (cities.isEmpty) return Center(child: Text('geo.no_cities'.tr()));

    return Column(
      children: cities.map((city) {
        final isCityExpanded = _expandedCityId == city.id;
        
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
          child: Column(
            children: [
              ListTile(
                title: Text(city.name),
                trailing: Icon(isCityExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown),
                onTap: () => _handleCityTap(city.id),
                tileColor: isCityExpanded ? Colors.grey.shade100 : null,
              ),
              if (isCityExpanded)
                _buildStreetsList(city.id)
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildStreetsList(String cityId) {
    final streets = _streetsCache[cityId] ?? [];
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Colors.grey.shade50,
      child: streets.isEmpty 
        ? Text('geo.no_streets'.tr(), style: const TextStyle(fontStyle: FontStyle.italic))
        : Column(
            children: streets.map((street) => ListTile(
              title: Text(street.name),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(LucideIcons.edit, size: 18), onPressed: () => _showStreetDialog(street: street)),
                  IconButton(icon: const Icon(LucideIcons.trash, size: 18, color: Colors.red), onPressed: () => _deleteStreet(street)),
                ],
              ),
            )).toList(),
          ),
    );
  }
}