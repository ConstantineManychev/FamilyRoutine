import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import '../widgets/smart_geo_input.dart';
import 'places_screen.dart';

class PlaceDetailScreen extends ConsumerStatefulWidget
{
  final String? placeId;

  const PlaceDetailScreen({super.key, this.placeId});

  @override
  ConsumerState<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends ConsumerState<PlaceDetailScreen>
{
  final _nameCtrl = TextEditingController();
  final _houseCtrl = TextEditingController();
  final _aptCtrl = TextEditingController();
  final _zipCtrl = TextEditingController();
  final _merchCtrl = TextEditingController();

  List<CountryDto> _countries = const [];
  List<CityDto> _cities = const [];
  List<StreetDto> _streets = const [];
  List<PlaceAddrDto> _otherAddrs = const [];

  CountryDto? _selCountry;
  CityDto? _selCity;
  StreetDto? _selStreet;
  String? _mainAddrId;
  Object? _loadError;
  bool _isLoading = true;
  bool _isSaving = false;

  bool get _isEdit => widget.placeId != null;

  @override
  void initState()
  {
    super.initState();
    _initData();
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    _houseCtrl.dispose();
    _aptCtrl.dispose();
    _zipCtrl.dispose();
    _merchCtrl.dispose();
    super.dispose();
  }

  Future<void> _initData() async
  {
    setState(()
    {
      _isLoading = true;
      _loadError = null;
    });

    try
    {
      final api = ref.read(apiProv);
      _countries = await api.getCountries();

      if (_isEdit)
      {
        final place = await api.getPlace(widget.placeId!);
        _nameCtrl.text = place.name;

        final mainAddr = place.mainAddr;
        _otherAddrs = place.addrs.where((aAddr) => aAddr.id != mainAddr?.id).toList();

        if (mainAddr != null)
        {
          _mainAddrId = mainAddr.id;
          _selCountry = _countries.where((aCountry) => aCountry.id == mainAddr.countryId).firstOrNull;

          if (_selCountry != null)
          {
            _cities = await api.getCities(_selCountry!.id);
            _selCity = _cities.where((aCity) => aCity.id == mainAddr.cityId).firstOrNull;
          }

          if (_selCity != null)
          {
            _streets = await api.getStreets(_selCity!.id);
            _selStreet = _streets.where((aStreet) => aStreet.id == mainAddr.streetId).firstOrNull;
          }

          _houseCtrl.text = mainAddr.houseNum;
          _aptCtrl.text = mainAddr.apt ?? '';
          _zipCtrl.text = mainAddr.zip;
          _merchCtrl.text = mainAddr.merchantId ?? '';
        }
      }
    }
    catch (aError)
    {
      _loadError = aError;
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadCities(String aCountryId) async
  {
    try
    {
      final cities = await ref.read(apiProv).getCities(aCountryId);
      if (mounted)
      {
        setState(()
        {
          _cities = cities;
          _selCity = null;
          _selStreet = null;
          _streets = const [];
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

  Future<void> _loadStreets(String aCityId) async
  {
    try
    {
      final streets = await ref.read(apiProv).getStreets(aCityId);
      if (mounted)
      {
        setState(()
        {
          _streets = streets;
          _selStreet = null;
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

  Future<void> _handleCityCreate(String aCityName) async
  {
    final country = _selCountry;
    if (country == null)
    {
      return;
    }

    final isConfirmed = await confirmAction(
      context,
      aTitle: 'places.city'.tr(),
      aMessage: 'places.create_city_prompt'.tr(namedArgs: {'city': aCityName, 'country': country.name}),
      aIsDestructive: false,
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    try
    {
      final city = await ref.read(apiProv).createCity(country.id, aCityName);
      await _loadCities(country.id);
      if (mounted)
      {
        setState(() => _selCity = _cities.where((aCity) => aCity.id == city.id).firstOrNull);
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

  Future<void> _handleStreetCreate(String aStreetName) async
  {
    final city = _selCity;
    final country = _selCountry;
    if (city == null || country == null)
    {
      return;
    }

    final isConfirmed = await confirmAction(
      context,
      aTitle: 'places.street'.tr(),
      aMessage: 'places.create_street_prompt'.tr(
        namedArgs: {'street': aStreetName, 'city': city.name, 'country': country.name},
      ),
      aIsDestructive: false,
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    try
    {
      final street = await ref.read(apiProv).createStreet(city.id, aStreetName);
      await _loadStreets(city.id);
      if (mounted)
      {
        setState(() => _selStreet = _streets.where((aStreet) => aStreet.id == street.id).firstOrNull);
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

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'places.edit'.tr(),
      aMessage: 'common.delete_confirm'.tr(),
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    setState(() => _isSaving = true);

    try
    {
      await ref.read(apiProv).deletePlace(widget.placeId!);
      ref.invalidate(placesProv);
      if (mounted)
      {
        context.go('/app/places');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
      }
    }
  }

  String? _missingFieldKey()
  {
    if (_nameCtrl.text.trim().isEmpty)
    {
      return 'places.err_name_req';
    }
    if (_selCountry == null)
    {
      return 'places.err_country_req';
    }
    if (_selCity == null)
    {
      return 'places.err_city_req';
    }
    if (_selStreet == null)
    {
      return 'places.err_street_req';
    }
    if (_houseCtrl.text.trim().isEmpty || _zipCtrl.text.trim().isEmpty)
    {
      return 'places.err_house_zip_req';
    }
    return null;
  }

  Future<void> _save() async
  {
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (!mounted)
    {
      return;
    }

    final missingKey = _missingFieldKey();
    if (missingKey != null)
    {
      showInfoSnack(context, missingKey.tr());
      return;
    }

    setState(() => _isSaving = true);

    final mainAddr = PlaceAddrDto(
      id: _mainAddrId,
      isMain: true,
      countryId: _selCountry!.id,
      cityId: _selCity!.id,
      streetId: _selStreet!.id,
      houseNum: _houseCtrl.text.trim(),
      apt: _aptCtrl.text.trim().isEmpty ? null : _aptCtrl.text.trim(),
      zip: _zipCtrl.text.trim(),
      merchantId: _merchCtrl.text.trim().isEmpty ? null : _merchCtrl.text.trim(),
    );

    final addrs = [mainAddr, ..._otherAddrs.map((aAddr) => aAddr.copyWith(aIsMain: false))];

    try
    {
      final api = ref.read(apiProv);
      if (_isEdit)
      {
        await api.updatePlace(widget.placeId!, _nameCtrl.text.trim(), addrs);
      }
      else
      {
        await api.createPlace(_nameCtrl.text.trim(), addrs);
      }

      ref.invalidate(placesProv);
      if (mounted)
      {
        context.go('/app/places');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
      }
    }
  }

  InputDecoration _decoration(String aLabelKey) => InputDecoration(
        labelText: aLabelKey.tr(),
        border: const OutlineInputBorder(),
      );

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    if (_isLoading)
    {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null)
    {
      return ErrorRetry(error: _loadError!, onRetry: _initData);
    }

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'places.edit'.tr() : 'places.add'.tr(),
          actions: [
            if (_isEdit)
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(LucideIcons.trash, color: Colors.red, size: 18),
                label: Text('common.delete'.tr()),
              ),
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(LucideIcons.save, size: 18),
              label: Text('common.save'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _nameCtrl,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          decoration: _decoration('places.name'),
        ),
        const SizedBox(height: 24),
        DropdownButtonFormField<CountryDto>(
          initialValue: _selCountry,
          decoration: _decoration('places.country'),
          items: _countries.map((aCountry) => DropdownMenuItem(value: aCountry, child: Text(aCountry.name))).toList(),
          onChanged: (aCountry)
          {
            setState(() => _selCountry = aCountry);
            if (aCountry != null)
            {
              _loadCities(aCountry.id);
            }
          },
        ),
        const SizedBox(height: 16),
        SmartGeoInput(
          key: ValueKey('city-${_selCountry?.id}'),
          label: 'places.city'.tr(),
          initialValue: _selCity?.name,
          options: _cities.map((aCity) => aCity.name).toList(),
          onSelected: (aName)
          {
            final city = _cities.firstWhere((aCity) => aCity.name == aName);
            setState(() => _selCity = city);
            _loadStreets(city.id);
          },
          onCreateRequested: _handleCityCreate,
        ),
        const SizedBox(height: 16),
        SmartGeoInput(
          key: ValueKey('street-${_selCity?.id}'),
          label: 'places.street'.tr(),
          initialValue: _selStreet?.name,
          options: _streets.map((aStreet) => aStreet.name).toList(),
          onSelected: (aName) => setState(() => _selStreet = _streets.firstWhere((aStreet) => aStreet.name == aName)),
          onCreateRequested: _handleStreetCreate,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _houseCtrl,
                inputFormatters: [LengthLimitingTextInputFormatter(50)],
                decoration: _decoration('places.house'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _aptCtrl,
                inputFormatters: [LengthLimitingTextInputFormatter(50)],
                decoration: _decoration('places.apt'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _zipCtrl,
          inputFormatters: [LengthLimitingTextInputFormatter(50)],
          decoration: _decoration('places.zip'),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _merchCtrl,
          inputFormatters: [LengthLimitingTextInputFormatter(255)],
          decoration: _decoration('places.merchant_id'),
        ),
        if (_otherAddrs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'places.other_addrs'.tr(namedArgs: {'count': '${_otherAddrs.length}'}),
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ],
    );
  }
}
