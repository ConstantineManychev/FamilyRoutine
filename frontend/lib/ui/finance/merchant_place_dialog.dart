import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../dicts/scope_widgets.dart';
import '../places/places_screen.dart';

const int _minWordLength = 3;

List<String> _words(String aText) => aText
    .toLowerCase()
    .split(RegExp(r'[^\p{L}]+', unicode: true))
    .where((aWord) => aWord.length >= _minWordLength)
    .toList();

bool _isWordMatch(String aLeft, String aRight) => aLeft.startsWith(aRight) || aRight.startsWith(aLeft);

String suggestPlaceName(String aMerchantName)
{
  final words = aMerchantName
      .split(RegExp(r'\s+'))
      .where((aWord) => aWord.isNotEmpty && !aWord.contains(RegExp(r'\d')))
      .toList();
  if (words.isEmpty)
  {
    return aMerchantName.trim();
  }
  final isShouting = aMerchantName == aMerchantName.toUpperCase();
  final picked = isShouting ? words.take(1) : words;
  return picked
      .map((aWord) => isShouting ? '${aWord[0]}${aWord.substring(1).toLowerCase()}' : aWord)
      .join(' ');
}

bool isSuggestedPlace(PlaceDto aPlace, String aMerchantName)
{
  final merchantWords = _words(aMerchantName);
  return _words(aPlace.name).any((aWord) => merchantWords.any((aOther) => _isWordMatch(aWord, aOther)));
}

String? suggestBranch(PlaceDto aPlace, String aMerchantName)
{
  final nameWords = _words(aPlace.name);
  final merchantWords = _words(aMerchantName)
      .where((aWord) => !nameWords.any((aName) => _isWordMatch(aName, aWord)))
      .toList();
  for (final addr in aPlace.addrs)
  {
    final labelWords = _words(addr.label ?? '');
    if (labelWords.any((aWord) => merchantWords.any((aOther) => _isWordMatch(aWord, aOther))))
    {
      return addr.id;
    }
  }
  return null;
}

Future<bool?> showMerchantPlaceDialog(BuildContext aContext, TxDto aTx)
{
  return showDialog<bool>(context: aContext, builder: (_) => _MerchantPlaceDialog(tx: aTx));
}

class _MerchantPlaceDialog extends ConsumerStatefulWidget
{
  final TxDto tx;

  const _MerchantPlaceDialog({required this.tx});

  @override
  ConsumerState<_MerchantPlaceDialog> createState() => _MerchantPlaceDialogState();
}

class _MerchantPlaceDialogState extends ConsumerState<_MerchantPlaceDialog>
{
  final _searchCtrl = TextEditingController();
  late final _nameCtrl = TextEditingController(text: suggestPlaceName(_merchantName));

  List<PlaceDto>? _places;
  String? _placeId;
  String? _addrId;
  String? _familyId;
  bool _isScopeChosen = false;
  bool _isCreating = false;
  bool _isBusy = false;
  Object? _loadError;

  String get _merchantName => widget.tx.merchantName ?? '';

  String? _scopeOf(List<FamDto>? aFams) => _isScopeChosen ? _familyId : defaultFamilyId(aFams);

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    try
    {
      final places = await ref.read(apiProv).getPlaces();
      if (!mounted)
      {
        return;
      }
      final current = places.where((aPlace) => aPlace.id == widget.tx.placeId).firstOrNull;
      final suggested = places.where((aPlace) => isSuggestedPlace(aPlace, _merchantName)).firstOrNull;
      final selected = current ?? suggested;
      setState(()
      {
        _places = places;
        _placeId = selected?.id;
        _addrId = widget.tx.placeAddrId ?? (selected == null ? null : suggestBranch(selected, _merchantName));
        _isCreating = places.isEmpty;
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
  }

  PlaceDto? get _selected => _places?.where((aPlace) => aPlace.id == _placeId).firstOrNull;

  List<PlaceDto> _visiblePlaces()
  {
    final query = _searchCtrl.text.trim().toLowerCase();
    final places = (_places ?? const <PlaceDto>[])
        .where((aPlace) => query.isEmpty || aPlace.name.toLowerCase().contains(query))
        .toList();
    int rank(PlaceDto aPlace) => isSuggestedPlace(aPlace, _merchantName) ? 0 : 1;
    places.sort((aLeft, aRight)
    {
      final byRank = rank(aLeft).compareTo(rank(aRight));
      return byRank != 0 ? byRank : aLeft.name.toLowerCase().compareTo(aRight.name.toLowerCase());
    });
    return places;
  }

  void _select(PlaceDto aPlace)
  {
    setState(()
    {
      _placeId = aPlace.id;
      _addrId = suggestBranch(aPlace, _merchantName);
    });
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
      ref.invalidate(placesProv);
      if (mounted)
      {
        Navigator.of(context).pop(true);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _save()
  {
    final api = ref.read(apiProv);
    final merchantId = widget.tx.merchantId!;
    if (_isCreating)
    {
      final name = _nameCtrl.text.trim();
      if (name.isEmpty)
      {
        showInfoSnack(context, 'places.err_name_req'.tr());
        return Future.value();
      }
      return _run(() async
      {
        final place = await api.createPlace(name, const [], aFamilyId: _scopeOf(ref.read(famsProv).valueOrNull));
        await api.linkMerchant(merchantId, place.id);
      });
    }
    return _run(() => api.linkMerchant(merchantId, _placeId!, aPlaceAddrId: _addrId));
  }

  @override
  Widget build(BuildContext aContext)
  {
    final places = _places;
    final fams = ref.watch(famsProv).valueOrNull ?? const <FamDto>[];
    final canSave = !_isBusy && places != null && (_isCreating || _placeId != null);

    return AlertDialog(
      title: Text('finance.place_link_title'.tr()),
      content: SizedBox(
        width: 480,
        child: _loadError != null
            ? ErrorRetry(error: _loadError!, onRetry: _load)
            : places == null
                ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'finance.place_link_hint'.tr(args: [_merchantName]),
                          style: const TextStyle(color: inkSecondary),
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(value: false, label: Text('finance.place_existing'.tr())),
                            ButtonSegment(value: true, label: Text('finance.place_new'.tr())),
                          ],
                          selected: {_isCreating},
                          onSelectionChanged: (aSelected) => setState(() => _isCreating = aSelected.first),
                        ),
                        const SizedBox(height: 12),
                        if (_isCreating) ..._buildCreate(fams) else ..._buildPick(aContext),
                      ],
                    ),
                  ),
      ),
      actions: [
        if (widget.tx.isMerchantLinked)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            onPressed: _isBusy ? null : () => _run(() => ref.read(apiProv).unlinkMerchant(widget.tx.merchantId!)),
            child: Text('finance.place_unlink'.tr()),
          ),
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: canSave ? _save : null, child: Text('common.save'.tr())),
      ],
    );
  }

  List<Widget> _buildCreate(List<FamDto> aFams)
  {
    return [
      Semantics(
        container: true,
        child: TextField(
          controller: _nameCtrl,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          decoration: InputDecoration(labelText: 'places.name'.tr(), border: const OutlineInputBorder()),
        ),
      ),
      if (aFams.isNotEmpty) ...[
        const SizedBox(height: 12),
        ScopeDropdown(
          fams: aFams,
          familyId: _scopeOf(aFams),
          onChanged: (aValue) => setState(()
          {
            _familyId = aValue;
            _isScopeChosen = true;
          }),
        ),
      ],
      const SizedBox(height: 8),
      Text('finance.place_new_hint'.tr(), style: const TextStyle(fontSize: 12, color: inkMuted)),
    ];
  }

  List<Widget> _buildPick(BuildContext aContext)
  {
    final visible = _visiblePlaces();
    final selected = _selected;

    return [
      Semantics(
        container: true,
        child: TextField(
          controller: _searchCtrl,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(AppIcons.search, size: 18),
            labelText: 'finance.place_search'.tr(),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: visible.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text('finance.place_none_found'.tr(), style: const TextStyle(color: inkMuted)),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final place in visible)
                    ListTile(
                      dense: true,
                      selected: place.id == _placeId,
                      leading: Icon(place.id == _placeId ? AppIcons.checkCircle : AppIcons.store, size: 18),
                      title: Text(place.name),
                      subtitle: Text(
                        [
                          if (isSuggestedPlace(place, _merchantName)) 'finance.place_suggested'.tr(),
                          if (place.familyName != null) place.familyName!,
                        ].join(' · '),
                      ),
                      onTap: () => _select(place),
                    ),
                ],
              ),
      ),
      if (selected != null && selected.addrs.isNotEmpty) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          key: ValueKey('branch:${selected.id}:$_addrId'),
          initialValue: _addrId,
          isExpanded: true,
          decoration: InputDecoration(labelText: 'finance.place_branch'.tr(), border: const OutlineInputBorder()),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text('finance.place_any_branch'.tr())),
            for (final addr in selected.addrs)
              DropdownMenuItem<String?>(
                value: addr.id,
                child: Text(addr.label ?? '', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (aValue) => setState(() => _addrId = aValue),
        ),
      ],
    ];
  }
}
