import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/barcode_scanner.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../dicts/item_form.dart';
import 'nutrition_format.dart';

const Duration _searchDelay = Duration(milliseconds: 300);
const int _searchLimit = 30;

String foodSubtitle(BuildContext aContext, DictItemDto aItem)
{
  final nutrition = aItem.nutrition;
  if (nutrition.kcal == null)
  {
    return 'nutrition.no_nutrition'.tr();
  }
  return per100Line(aContext, Macros.fromNutrition(nutrition), aIsMl: aItem.unit == ItemUnit.liter);
}

class FoodSearchPanel extends ConsumerStatefulWidget
{
  final ValueChanged<DictItemDto> onPick;
  final List<Widget> idleChildren;
  final bool isAutofocus;

  const FoodSearchPanel({super.key, required this.onPick, this.idleChildren = const [], this.isAutofocus = false});

  @override
  ConsumerState<FoodSearchPanel> createState() => _FoodSearchPanelState();
}

class _FoodSearchPanelState extends ConsumerState<FoodSearchPanel>
{
  final _ctrl = TextEditingController();
  Timer? _timer;
  String _query = '';
  List<DictItemDto>? _results;
  Object? _error;
  bool _isBusy = false;

  @override
  void dispose()
  {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String aValue)
  {
    _timer?.cancel();
    _timer = Timer(_searchDelay, () => _search(aValue.trim()));
  }

  Future<void> _search(String aQuery)
  {
    setState(()
    {
      _query = aQuery;
      _error = null;
      if (aQuery.isEmpty)
      {
        _results = null;
      }
    });
    return aQuery.isEmpty ? Future.value() : _load(aQuery);
  }

  Future<void> _load(String aQuery) async
  {
    try
    {
      final items = await ref.read(apiProv).getItems(aQuery: aQuery, aLimit: _searchLimit, aKind: ItemKind.food);
      if (mounted && aQuery == _query)
      {
        setState(() => _results = items);
      }
    }
    catch (aError)
    {
      if (mounted && aQuery == _query)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _accept(DictItemDto aItem)
  {
    if (aItem.kind != ItemKind.food)
    {
      showInfoSnack(context, 'nutrition.not_food'.tr(args: [aItem.name]));
      return;
    }
    widget.onPick(aItem);
  }

  Future<void> _create(String aInitial) async
  {
    final created = await showItemCreateDialog(context, aInitial, aKind: ItemKind.food);
    if (created != null && mounted)
    {
      _accept(created);
    }
  }

  Future<void> _scan() async
  {
    final code = await scanBarcode(context);
    if (code == null || !mounted)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      final found = (await ref.read(apiProv).getItems(aBarcode: code, aLimit: 1)).firstOrNull;
      if (!mounted)
      {
        return;
      }
      setState(() => _isBusy = false);
      if (found != null)
      {
        _accept(found);
      }
      else
      {
        await _create(code);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
        showErrorSnack(context, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final results = _results;
    final List<Widget> body;
    if (_query.isEmpty)
    {
      body = widget.idleChildren;
    }
    else if (_error != null)
    {
      body = [Padding(padding: const EdgeInsets.all(24), child: ErrorRetry(error: _error!, onRetry: () => _load(_query)))];
    }
    else if (results == null)
    {
      body = const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))];
    }
    else
    {
      body = [
        if (results.isEmpty) BlockEmpty('nutrition.nothing_found'.tr()),
        for (final item in results)
          ListTile(
            onTap: () => _accept(item),
            leading: Icon(AppIcons.apple, color: palette.inkSecondary),
            title: Text(item.name),
            subtitle: Text(
              foodSubtitle(aContext, item),
              style: TextStyle(color: item.nutrition.kcal == null ? palette.warning : palette.inkSecondary),
            ),
          ),
        ListTile(
          onTap: () => _create(_query),
          leading: Icon(AppIcons.plusCircle, color: aContext.colors.primary),
          title: Text('nutrition.create_product'.tr(args: [_query])),
        ),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('nutrition.food_search'),
                  controller: _ctrl,
                  autofocus: widget.isAutofocus,
                  textInputAction: TextInputAction.search,
                  inputFormatters: [LengthLimitingTextInputFormatter(100)],
                  onChanged: _onChanged,
                  onSubmitted: (aValue) => _search(aValue.trim()),
                  decoration: InputDecoration(
                    hintText: 'nutrition.search_food'.tr(),
                    prefixIcon: const Icon(AppIcons.search, size: 18),
                    isDense: true,
                    filled: true,
                    fillColor: palette.surfaceMuted,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'scanner.title'.tr(),
                onPressed: _isBusy ? null : _scan,
                icon: _isBusy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(AppIcons.scanBarcode),
              ),
            ],
          ),
        ),
        Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 24), children: body)),
      ],
    );
  }
}

Future<DictItemDto?> pickFood(BuildContext aContext)
{
  return Navigator.of(aContext).push<DictItemDto>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (aPageContext) => SubPage(
      title: 'nutrition.pick_ingredient'.tr(),
      child: FoodSearchPanel(isAutofocus: true, onPick: (aItem) => Navigator.of(aPageContext).pop(aItem)),
    ),
  ));
}
