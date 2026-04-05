import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../widgets/smart_geo_input.dart';

class PlaceDetailScreen extends ConsumerStatefulWidget {
  final String? placeId;
  final VoidCallback onSaved;

  const PlaceDetailScreen({super.key, this.placeId, required this.onSaved});

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

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    setState(() => _isLoading = true);
    try {
      final api = ref.read(apiProv);
      final countries = await api.getCountries();
      _countries = countries;

      if (widget.placeId != null) {
        final place = await api.getPlaceDetail(widget.placeId!);
        _nameCtrl.text = place.name;
        
        if (place.addrs.isNotEmpty) {
          final mainAddr = place.addrs.firstWhere((a) => a.isMain, orElse: () => place.addrs.first);
          
          _selCountry = _countries.where((c) => c.id == mainAddr.countryId).firstOrNull;
          
          if (_selCountry != null) {
            _cities = await api.getCities(_selCountry!.id);
            _selCity = _cities.where((c) => c.id == mainAddr.cityId).firstOrNull;
          }
          
          if (_selCity != null) {
            _streets = await api.getStreets(_selCity!.id);
            _selStreet = _streets.where((s) => s.id == mainAddr.streetId).firstOrNull;
          }

          _houseCtrl.text = mainAddr.houseNum;
          _aptCtrl.text = mainAddr.apt ?? '';
          _zipCtrl.text = mainAddr.zip;
          _merchCtrl.text = mainAddr.merchantId ?? '';
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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

  Future<void> _delete() async {
    final conf = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('common.delete_confirm'.tr()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.no'.tr())),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true), 
            child: Text('common.yes'.tr())
          ),
        ],
      ),
    );

    if (conf == true) {
      setState(() => _isLoading = true);
      try {
        await ref.read(apiProv).deletePlace(widget.placeId!);
        widget.onSaved();
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 150)); 

    if (!mounted) return;

    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('places.err_name_req'.tr())));
      return;
    }
    if (_selCountry == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('places.err_country_req'.tr())));
      return;
    }
    if (_selCity == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('places.err_city_req'.tr())));
      return;
    }
    if (_selStreet == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('places.err_street_req'.tr())));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final addr = PlaceAddrDto(
        id: null,
        isMain: true,
        countryId: _selCountry!.id,
        cityId: _selCity!.id,
        streetId: _selStreet!.id,
        houseNum: _houseCtrl.text.trim(),
        apt: _aptCtrl.text.trim().isEmpty ? null : _aptCtrl.text.trim(),
        zip: _zipCtrl.text.trim(),
        merchantId: _merchCtrl.text.trim().isEmpty ? null : _merchCtrl.text.trim(),
      );

      final place = PlaceDto(
        id: widget.placeId ?? const Uuid().v4(),
        name: _nameCtrl.text.trim(),
        addrs: [addr],
      );

      if (widget.placeId == null) {
        await ref.read(apiProv).createPlace(place);
      } else {
        await ref.read(apiProv).updatePlace(widget.placeId!, place);
      }
      widget.onSaved();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('places.err_save'.tr())));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.placeId == null ? 'places.add'.tr() : 'places.edit'.tr()), 
        actions: [
          if (widget.placeId != null)
            IconButton(icon: const Icon(LucideIcons.trash, color: Colors.red), onPressed: _delete),
          IconButton(icon: const Icon(Icons.save), onPressed: _save)
        ]
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: 'places.name'.tr(), border: const OutlineInputBorder())),
              const SizedBox(height: 24),
              DropdownButtonFormField<CountryDto>(
                value: _selCountry,
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