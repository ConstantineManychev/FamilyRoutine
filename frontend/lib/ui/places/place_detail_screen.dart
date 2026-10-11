import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../dicts/scope_widgets.dart';
import '../widgets/smart_geo_input.dart';
import 'places_screen.dart';

class _AddrDraft
{
  String? id;
  String? countryId;
  String? cityId;
  String? streetId;
  String houseNum;
  String apt;
  String zip;
  String merchantId;
  String? label;

  _AddrDraft({
    this.id,
    this.countryId,
    this.cityId,
    this.streetId,
    this.houseNum = '',
    this.apt = '',
    this.zip = '',
    this.merchantId = '',
    this.label,
  });

  factory _AddrDraft.from(PlaceAddrDto aAddr) => _AddrDraft(
        id: aAddr.id,
        countryId: aAddr.countryId,
        cityId: aAddr.cityId,
        streetId: aAddr.streetId,
        houseNum: aAddr.houseNum,
        apt: aAddr.apt ?? '',
        zip: aAddr.zip,
        merchantId: aAddr.merchantId ?? '',
        label: aAddr.label,
      );

  String? get missingKey
  {
    if (countryId == null)
    {
      return 'places.err_country_req';
    }
    if (cityId == null)
    {
      return 'places.err_city_req';
    }
    if (streetId == null)
    {
      return 'places.err_street_req';
    }
    if (houseNum.trim().isEmpty)
    {
      return 'places.err_house_zip_req';
    }
    return null;
  }

  PlaceAddrDto toDto(bool aIsMain) => PlaceAddrDto(
        id: id,
        isMain: aIsMain,
        countryId: countryId!,
        cityId: cityId!,
        streetId: streetId!,
        houseNum: houseNum.trim(),
        apt: apt.trim().isEmpty ? null : apt.trim(),
        zip: zip.trim(),
        merchantId: merchantId.trim().isEmpty ? null : merchantId.trim(),
      );
}

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
  final List<_AddrDraft> _addrs = [_AddrDraft()];

  PlaceDto? _place;
  CountryDto? _selCountry;
  CityDto? _selCity;
  StreetDto? _selStreet;
  int _current = 0;
  int _mainIndex = 0;
  String? _familyId;
  Object? _loadError;
  bool _isLoading = true;
  bool _isSaving = false;

  bool get _isEdit => widget.placeId != null;

  bool get _isEditable => _place?.isEditable ?? true;

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
        _place = place;
        _nameCtrl.text = place.name;
        final mainAddr = place.mainAddr;
        _addrs
          ..clear()
          ..addAll(place.addrs.map(_AddrDraft.from));
        if (_addrs.isEmpty)
        {
          _addrs.add(_AddrDraft());
        }
        _mainIndex = mainAddr == null ? 0 : place.addrs.indexOf(mainAddr).clamp(0, _addrs.length - 1);
        _current = _mainIndex;
      }

      await _loadForm(_addrs[_current]);
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

  Future<void> _loadForm(_AddrDraft aDraft) async
  {
    final api = ref.read(apiProv);
    _selCountry = _countries.where((aCountry) => aCountry.id == aDraft.countryId).firstOrNull;
    _cities = _selCountry == null ? const [] : await api.getCities(_selCountry!.id);
    _selCity = _cities.where((aCity) => aCity.id == aDraft.cityId).firstOrNull;
    _streets = _selCity == null ? const [] : await api.getStreets(_selCity!.id);
    _selStreet = _streets.where((aStreet) => aStreet.id == aDraft.streetId).firstOrNull;
    _houseCtrl.text = aDraft.houseNum;
    _aptCtrl.text = aDraft.apt;
    _zipCtrl.text = aDraft.zip;
    _merchCtrl.text = aDraft.merchantId;
  }

  void _commitForm()
  {
    final draft = _addrs[_current];
    draft
      ..countryId = _selCountry?.id
      ..cityId = _selCity?.id
      ..streetId = _selStreet?.id
      ..houseNum = _houseCtrl.text
      ..apt = _aptCtrl.text
      ..zip = _zipCtrl.text
      ..merchantId = _merchCtrl.text;
  }

  Future<void> _selectAddr(int aIndex) async
  {
    if (aIndex == _current)
    {
      return;
    }
    _commitForm();
    setState(() => _current = aIndex);
    await _reloadForm();
  }

  Future<void> _reloadForm() async
  {
    try
    {
      await _loadForm(_addrs[_current]);
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    if (mounted)
    {
      setState(() {});
    }
  }

  Future<void> _addBranch()
  {
    _commitForm();
    final source = _addrs[_current];
    setState(()
    {
      _addrs.add(_AddrDraft(countryId: source.countryId, cityId: source.cityId));
      _current = _addrs.length - 1;
    });
    return _reloadForm();
  }

  Future<void> _removeBranch()
  {
    setState(()
    {
      _addrs.removeAt(_current);
      if (_mainIndex == _current)
      {
        _mainIndex = 0;
      }
      else if (_mainIndex > _current)
      {
        _mainIndex--;
      }
      _current = _current.clamp(0, _addrs.length - 1);
    });
    return _reloadForm();
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

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isSaving = true);

    try
    {
      await aAction();
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

    await _run(() async
    {
      await ref.read(apiProv).deletePlace(widget.placeId!);
      ref.invalidate(placesProv);
      if (mounted)
      {
        context.go('/app/places');
      }
    });
  }

  Future<void> _share() async
  {
    final fams = ref.read(famsProv).valueOrNull ?? const <FamDto>[];
    final familyId = await showShareToFamilyDialog(context, fams, 'catalog.share_place'.tr());
    if (familyId == null || !mounted)
    {
      return;
    }

    await _run(() async
    {
      final shared = await ref.read(apiProv).sharePlace(widget.placeId!, familyId);
      ref.invalidate(placesProv);
      if (mounted)
      {
        setState(() => _place = shared);
      }
    });
  }

  Future<void> _save() async
  {
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (!mounted)
    {
      return;
    }

    _commitForm();
    if (_nameCtrl.text.trim().isEmpty)
    {
      showInfoSnack(context, 'places.err_name_req'.tr());
      return;
    }

    for (var index = 0; index < _addrs.length; index++)
    {
      final missingKey = _addrs[index].missingKey;
      if (missingKey != null)
      {
        await _selectAddr(index);
        if (mounted)
        {
          showInfoSnack(context, missingKey.tr());
        }
        return;
      }
    }

    final addrs = [for (var index = 0; index < _addrs.length; index++) _addrs[index].toDto(index == _mainIndex)];

    await _run(() async
    {
      final api = ref.read(apiProv);
      if (_isEdit)
      {
        await api.updatePlace(widget.placeId!, _nameCtrl.text.trim(), addrs);
      }
      else
      {
        await api.createPlace(_nameCtrl.text.trim(), addrs, aFamilyId: _familyId);
      }

      ref.invalidate(placesProv);
      if (mounted)
      {
        context.go('/app/places');
      }
    });
  }

  InputDecoration _decoration(String aLabelKey) => InputDecoration(
        labelText: aLabelKey.tr(),
        border: const OutlineInputBorder(),
      );

  String _branchLabel(int aIndex)
  {
    final label = 'places.branch_n'.tr(args: ['${aIndex + 1}']);
    return aIndex == _mainIndex ? '$label · ${'places.main'.tr()}' : label;
  }

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

    final place = _place;
    final fams = ref.watch(famsProv).valueOrNull ?? const <FamDto>[];
    final canShare = place != null && place.familyId == null && place.isEditable && fams.isNotEmpty;
    final isEnabled = _isEditable;

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'places.edit'.tr() : 'places.add'.tr(),
          actions: [
            if (canShare)
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _share,
                icon: const Icon(AppIcons.users, size: 18),
                label: Text('catalog.share_place'.tr()),
              ),
            if (_isEdit && isEnabled)
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(AppIcons.trash, color: Colors.red, size: 18),
                label: Text('common.delete'.tr()),
              ),
            if (isEnabled)
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(AppIcons.save, size: 18),
                label: Text('common.save'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (place?.familyName != null) ...[
          Align(alignment: Alignment.centerLeft, child: FamilyBadge(name: place!.familyName!)),
          const SizedBox(height: 12),
        ],
        if (!isEnabled) ...[
          Row(
            children: [
              const Icon(AppIcons.lock, size: 18, color: inkMuted),
              const SizedBox(width: 8),
              Expanded(child: Text('places.family_readonly_hint'.tr(), style: const TextStyle(color: inkSecondary))),
            ],
          ),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _nameCtrl,
          enabled: isEnabled,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          decoration: _decoration('places.name'),
        ),
        if (!_isEdit && fams.isNotEmpty) ...[
          const SizedBox(height: 16),
          ScopeDropdown(fams: fams, familyId: _familyId, onChanged: (aValue) => setState(() => _familyId = aValue)),
        ],
        const SizedBox(height: 24),
        Text('places.branches'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('places.branches_hint'.tr(), style: const TextStyle(fontSize: 12, color: inkSecondary)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var index = 0; index < _addrs.length; index++)
              ChoiceChip(
                showCheckmark: false,
                avatar: Icon(index == _mainIndex ? AppIcons.store : AppIcons.mapPin, size: 16),
                label: Text(_branchLabel(index)),
                selected: index == _current,
                onSelected: (_) => _selectAddr(index),
              ),
            if (isEnabled)
              TextButton.icon(
                onPressed: _addBranch,
                icon: const Icon(AppIcons.plus, size: 16),
                label: Text('places.add_branch'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 16),
        ..._buildAddrForm(isEnabled),
        if (isEnabled && _addrs.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (_current != _mainIndex)
                TextButton.icon(
                  onPressed: () => setState(() => _mainIndex = _current),
                  icon: const Icon(AppIcons.store, size: 16),
                  label: Text('places.make_main'.tr()),
                ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.red.shade800),
                onPressed: _removeBranch,
                icon: const Icon(AppIcons.trash2, size: 16),
                label: Text('places.remove_branch'.tr()),
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _buildAddrForm(bool aIsEnabled)
  {
    return [
      DropdownButtonFormField<CountryDto>(
        key: ValueKey('country-$_current'),
        initialValue: _selCountry,
        decoration: _decoration('places.country'),
        items: _countries.map((aCountry) => DropdownMenuItem(value: aCountry, child: Text(aCountry.name))).toList(),
        onChanged: aIsEnabled
            ? (aCountry)
            {
              setState(() => _selCountry = aCountry);
              if (aCountry != null)
              {
                _loadCities(aCountry.id);
              }
            }
            : null,
      ),
      const SizedBox(height: 16),
      IgnorePointer(
        ignoring: !aIsEnabled,
        child: SmartGeoInput(
          key: ValueKey('city-$_current-${_selCountry?.id}'),
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
      ),
      const SizedBox(height: 16),
      IgnorePointer(
        ignoring: !aIsEnabled,
        child: SmartGeoInput(
          key: ValueKey('street-$_current-${_selCity?.id}'),
          label: 'places.street'.tr(),
          initialValue: _selStreet?.name,
          options: _streets.map((aStreet) => aStreet.name).toList(),
          onSelected: (aName) => setState(() => _selStreet = _streets.firstWhere((aStreet) => aStreet.name == aName)),
          onCreateRequested: _handleStreetCreate,
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _houseCtrl,
              enabled: aIsEnabled,
              inputFormatters: [LengthLimitingTextInputFormatter(50)],
              decoration: _decoration('places.house'),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _aptCtrl,
              enabled: aIsEnabled,
              inputFormatters: [LengthLimitingTextInputFormatter(50)],
              decoration: _decoration('places.apt'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _zipCtrl,
        enabled: aIsEnabled,
        inputFormatters: [LengthLimitingTextInputFormatter(50)],
        decoration: _decoration('places.zip'),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _merchCtrl,
        enabled: aIsEnabled,
        inputFormatters: [LengthLimitingTextInputFormatter(255)],
        decoration: _decoration('places.merchant_id'),
      ),
    ];
  }
}
