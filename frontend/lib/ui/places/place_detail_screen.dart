import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../widgets/smart_geo_input.dart';

class PlaceDetailScreen extends ConsumerStatefulWidget {
  final VoidCallback onSaved;
  const PlaceDetailScreen({super.key, required this.onSaved});

  @override
  ConsumerState<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends ConsumerState<PlaceDetailScreen> {
  final _nameCtrl = TextEditingController();
  
  List<CountryDto> _countries = [];
  List<CityDto> _cities = [];
  List<StreetDto> _streets = [];
  
  CountryDto? _selCountry;
  CityDto? _selCity;
  StreetDto? _selStreet;
  
  final _houseCtrl = TextEditingController();
  final _aptCtrl = TextEditingController();
  final _zipCtrl = TextEditingController();
  final _merchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCountries();
  }

  Future<void> _loadCountries() async {
    final res = await ref.read(apiProv).getCountries(); // Реализуйте этот метод в api_svc.dart
    setState(() => _countries = res);
  }

  Future<void> _loadCities(String countryId) async {
    final res = await ref.read(apiProv).getCities(countryId);
    setState(() {
      _cities = res;
      _selCity = null;
      _selStreet = null;
    });
  }

  Future<void> _loadStreets(String cityId) async {
    final res = await ref.read(apiProv).getStreets(cityId);
    setState(() {
      _streets = res;
      _selStreet = null;
    });
  }

  Future<void> _handleCityCreate(String cityName) async {
    if (_selCountry == null) return;
    
    final conf = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('places.create_city_prompt'.tr(namedArgs: {'city': cityName, 'country': _selCountry!.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.no'.tr())),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('common.yes'.tr())),
        ],
      ),
    );

    if (conf == true) {
      final newCity = await ref.read(apiProv).createCity(_selCountry!.id, cityName);
      await _loadCities(_selCountry!.id);
      setState(() => _selCity = _cities.firstWhere((c) => c.id == newCity.id));
    }
  }

  Future<void> _handleStreetCreate(String streetName) async {
    if (_selCity == null || _selCountry == null) return;
    
    final conf = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('places.create_street_prompt'.tr(namedArgs: {'street': streetName, 'city': _selCity!.name, 'country': _selCountry!.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.no'.tr())),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text('common.yes'.tr())),
        ],
      ),
    );

    if (conf == true) {
      final newStreet = await ref.read(apiProv).createStreet(_selCity!.id, streetName);
      await _loadStreets(_selCity!.id);
      setState(() => _selStreet = _streets.firstWhere((s) => s.id == newStreet.id));
    }
  }

  Future<void> _save() async {
    if (_nameCtrl.text.isEmpty || _selCountry == null || _selCity == null || _selStreet == null) return;

    final addr = PlaceAddrDto(
      id: null,
      isMain: true,
      countryId: _selCountry!.id,
      cityId: _selCity!.id,
      streetId: _selStreet!.id,
      houseNum: _houseCtrl.text,
      apt: _aptCtrl.text.isEmpty ? null : _aptCtrl.text,
      zip: _zipCtrl.text,
      merchantId: _merchCtrl.text.isEmpty ? null : _merchCtrl.text,
    );

    final place = PlaceDto(
      id: const Uuid().v4(),
      name: _nameCtrl.text,
      addrs: [addr],
    );

    await ref.read(apiProv).createPlace(place);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('places.add'.tr()), actions: [
        IconButton(icon: const Icon(Icons.save), onPressed: _save)
      ]),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: 'places.name'.tr(), border: const OutlineInputBorder())),
          const SizedBox(height: 24),
          DropdownButtonFormField<CountryDto>(
            decoration: InputDecoration(labelText: 'places.country'.tr(), border: const OutlineInputBorder()),
            items: _countries.map((c) => DropdownMenuItem(value: c, child: Text(c.name))).toList(),
            onChanged: (c) {
              setState(() => _selCountry = c);
              if (c != null) _loadCities(c.id);
            },
          ),
          const SizedBox(height: 16),
          SmartGeoInput(
            label: 'places.city'.tr(),
            initialValue: _selCity?.name,
            options: _cities.map((c) => c.name).toList(),
            onSelected: (val) {
              final c = _cities.firstWhere((e) => e.name == val);
              setState(() => _selCity = c);
              _loadStreets(c.id);
            },
            onCreateRequested: _handleCityCreate,
          ),
          const SizedBox(height: 16),
          SmartGeoInput(
            label: 'places.street'.tr(),
            initialValue: _selStreet?.name,
            options: _streets.map((s) => s.name).toList(),
            onSelected: (val) => setState(() => _selStreet = _streets.firstWhere((e) => e.name == val)),
            onCreateRequested: _handleStreetCreate,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: TextField(controller: _houseCtrl, decoration: InputDecoration(labelText: 'places.house'.tr(), border: const OutlineInputBorder()))),
              const SizedBox(width: 16),
              Expanded(child: TextField(controller: _aptCtrl, decoration: InputDecoration(labelText: 'places.apt'.tr(), border: const OutlineInputBorder()))),
            ],
          ),
          const SizedBox(height: 16),
          TextField(controller: _zipCtrl, decoration: InputDecoration(labelText: 'places.zip'.tr(), border: const OutlineInputBorder())),
          const SizedBox(height: 16),
          TextField(controller: _merchCtrl, decoration: InputDecoration(labelText: 'places.merchant_id'.tr(), border: const OutlineInputBorder())),
        ],
      ),
    );
  }
}