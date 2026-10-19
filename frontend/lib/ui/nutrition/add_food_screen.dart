import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/snap_tab_view.dart';
import 'amount_sheet.dart';
import '../stock/stock_actions.dart';
import 'food_picker.dart';
import 'meal_target.dart';
import 'nutrition_format.dart';

const double _maxQuickKcal = 10000;
const double _maxQuickGrams = 1000;
const int _maxTitleLen = 200;

class AddFoodScreen extends ConsumerStatefulWidget
{
  final DateTime date;
  final String? markId;
  final String? personId;

  const AddFoodScreen({super.key, required this.date, this.markId, this.personId});

  @override
  ConsumerState<AddFoodScreen> createState() => _AddFoodScreenState();
}

class _AddFoodScreenState extends ConsumerState<AddFoodScreen>
{
  List<DayMeal>? _meals;
  MealTarget? _target;
  List<RecentFood>? _recent;
  List<Dish>? _dishes;
  Object? _dishesError;
  String _dishQuery = '';
  bool _isBusy = false;
  final _quickTitle = TextEditingController();
  final _quickKcal = TextEditingController();
  final _quickProt = TextEditingController();
  final _quickFat = TextEditingController();
  final _quickCarb = TextEditingController();

  @override
  void initState()
  {
    super.initState();
    _loadMeals();
    _loadRecent();
    _loadDishes();
  }

  Future<void> _loadMeals({String? aMarkId}) async
  {
    try
    {
      final day = await ref.read(apiProv).getNutritionDay(widget.date, aPersonId: widget.personId);
      if (mounted)
      {
        setState(()
        {
          _meals = day.meals;
          final markId = aMarkId ?? _target?.markId ?? widget.markId;
          _target = aMarkId == null && _target?.isNew == true
              ? _target
              : defaultMealTarget(widget.date, day.meals, aMarkId: markId);
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(()
        {
          _meals = const [];
          _target ??= defaultMealTarget(widget.date, const []);
        });
      }
    }
  }

  @override
  void dispose()
  {
    for (final ctrl in [_quickTitle, _quickKcal, _quickProt, _quickFat, _quickCarb])
    {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _loadRecent() async
  {
    try
    {
      final recent = await ref.read(apiProv).getRecentFoods(aPersonId: widget.personId);
      if (mounted)
      {
        setState(() => _recent = recent);
      }
    }
    catch (_)
    {
      if (mounted)
      {
        setState(() => _recent = const []);
      }
    }
  }

  Future<void> _loadDishes() async
  {
    try
    {
      final dishes = await ref.read(apiProv).getDishes();
      if (mounted)
      {
        setState(()
        {
          _dishes = dishes;
          _dishesError = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _dishesError = aError);
      }
    }
  }

  Future<void> _save(String aTitle, Map<String, dynamic> aPayload) async
  {
    setState(() => _isBusy = true);
    try
    {
      final target = _target;
      if (target == null)
      {
        return;
      }
      final api = ref.read(apiProv);
      final markId = await ensureMealBlock(api, target, aPersonId: widget.personId);
      final entry = await api.addMealEntry({
        'date': dateWire(widget.date),
        'status_mark_id': markId,
        if (widget.personId != null) 'person_id': widget.personId,
        ...aPayload,
      });
      if (!mounted)
      {
        return;
      }
      notifyNutritionChanged(ref);
      showInfoSnack(context, 'nutrition.added'.tr(args: [aTitle, mealLabel(target.kind)]));
      final itemId = entry.itemId;
      if (entry.isPackNeeded && itemId != null)
      {
        await packMassFlow(
          context,
          ref,
          itemId,
          aTitle,
          aReason: 'stock.pack_needed_hint'.tr(args: [formatGrams(context, entry.grams ?? 0, aIsMl: entry.isMl)]),
        );
        if (!mounted)
        {
          return;
        }
      }
      await Future.wait([_loadMeals(aMarkId: markId), _loadRecent()]);
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
        setState(() => _isBusy = false);
      }
    }
  }

  Future<DictItemDto?> _withNutrition(DictItemDto aItem) async
  {
    if (aItem.nutrition.kcal != null)
    {
      return aItem;
    }
    final isOpen = await confirmAction(
      context,
      aTitle: aItem.name,
      aMessage: 'nutrition.fill_nutrition'.tr(),
      aIsDestructive: false,
    );
    if (!isOpen || !mounted)
    {
      return null;
    }
    await context.push('/app/items/${aItem.id}');
    if (!mounted)
    {
      return null;
    }
    final refreshed = await ref.read(apiProv).getItem(aItem.id);
    return refreshed.nutrition.kcal == null ? null : refreshed;
  }

  Future<void> _pickItem(DictItemDto aItem, {double? aGrams, double? aPortions}) async
  {
    final item = await _withNutrition(aItem);
    if (item == null || !mounted)
    {
      return;
    }
    final result = await showAmountSheet(
      context,
      aTarget: AmountTarget.item(item),
      aGrams: aGrams,
      aPortions: aPortions,
    );
    if (result == null || !mounted)
    {
      return;
    }
    await _save(item.name, {'item_id': item.id, ...result.toJson()});
  }

  Future<void> _pickDish(Dish aDish, {double? aGrams, double? aPortions}) async
  {
    final batches = await dishBatches(ref.read(apiProv), aDish.id);
    if (!mounted)
    {
      return;
    }
    final result = await showAmountSheet(
      context,
      aTarget: AmountTarget.dish(aDish, aBatches: batches),
      aGrams: aGrams,
      aPortions: aPortions ?? (aGrams == null && aDish.portionG != null ? 1 : null),
    );
    if (result == null || !mounted)
    {
      return;
    }
    await _save(aDish.name, {'dish_id': aDish.id, ...result.toJson()});
  }

  Future<void> _pickRecent(RecentFood aFood) async
  {
    try
    {
      final api = ref.read(apiProv);
      final dishId = aFood.dishId;
      final itemId = aFood.itemId;
      if (dishId != null)
      {
        final dish = await api.getDish(dishId);
        if (mounted)
        {
          await _pickDish(dish, aGrams: aFood.portions == null ? aFood.grams : null, aPortions: aFood.portions);
        }
      }
      else if (itemId != null)
      {
        final item = await api.getItem(itemId);
        if (mounted)
        {
          await _pickItem(item, aGrams: aFood.portions == null ? aFood.grams : null, aPortions: aFood.portions);
        }
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

  Future<void> _newDish() async
  {
    await context.push('/app/dishes/new');
    await _loadDishes();
  }

  double? _quickValue(TextEditingController aCtrl) => parseAmountText(aCtrl.text);

  bool get _isQuickValid
  {
    final kcal = _quickValue(_quickKcal);
    if (kcal == null || kcal < 0 || kcal > _maxQuickKcal)
    {
      return false;
    }
    for (final ctrl in [_quickProt, _quickFat, _quickCarb])
    {
      final value = _quickValue(ctrl);
      if (ctrl.text.trim().isNotEmpty && (value == null || value < 0 || value > _maxQuickGrams))
      {
        return false;
      }
    }
    return true;
  }

  Future<void> _addQuick() async
  {
    if (!_isQuickValid)
    {
      return;
    }
    final title = _quickTitle.text.trim();
    String? wire(TextEditingController aCtrl) => _quickValue(aCtrl)?.toString();
    await _save(title.isEmpty ? 'nutrition.quick_title'.tr() : title, {
      'quick': {
        'title': title.isEmpty ? null : title,
        'kcal': wire(_quickKcal),
        'prot': wire(_quickProt),
        'fat': wire(_quickFat),
        'carb': wire(_quickCarb),
      },
    });
    if (mounted)
    {
      for (final ctrl in [_quickTitle, _quickKcal, _quickProt, _quickFat, _quickCarb])
      {
        ctrl.clear();
      }
      setState(() {});
    }
  }

  Widget _recentSection(BuildContext aContext)
  {
    final recent = _recent;
    if (recent == null || recent.isEmpty)
    {
      return const SizedBox.shrink();
    }
    final palette = aContext.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('nutrition.recent'.tr(), style: TextStyle(fontWeight: FontWeight.w700, color: palette.inkSecondary)),
        ),
        for (final food in recent)
          ListTile(
            onTap: _isBusy ? null : () => _pickRecent(food),
            leading: Icon(food.source == MealSource.dish ? AppIcons.cookingPot : AppIcons.apple, color: palette.inkSecondary),
            title: Text(food.title),
            subtitle: food.per100 == null ? null : Text(per100Line(aContext, food.per100!, aIsMl: food.isMl)),
            trailing: Icon(AppIcons.plus, color: aContext.colors.primary),
          ),
      ],
    );
  }

  Widget _dishesTab(BuildContext aContext)
  {
    final palette = aContext.palette;
    final dishes = _dishes;
    if (_dishesError != null)
    {
      return ErrorRetry(error: _dishesError!, onRetry: _loadDishes);
    }
    if (dishes == null)
    {
      return const Center(child: CircularProgressIndicator());
    }
    final query = _dishQuery.toLowerCase();
    final visible = dishes.where((aDish) => query.isEmpty || aDish.name.toLowerCase().contains(query)).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            inputFormatters: [LengthLimitingTextInputFormatter(100)],
            onChanged: (aValue) => setState(() => _dishQuery = aValue.trim()),
            decoration: InputDecoration(
              hintText: 'nutrition.search_dish'.tr(),
              prefixIcon: const Icon(AppIcons.search, size: 18),
              isDense: true,
              filled: true,
              fillColor: palette.surfaceMuted,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (visible.isEmpty) BlockEmpty(dishes.isEmpty ? 'nutrition.no_dishes'.tr() : 'nutrition.nothing_found'.tr()),
        for (final dish in visible)
          ListTile(
            onTap: _isBusy ? null : () => _pickDish(dish),
            leading: Icon(AppIcons.cookingPot, color: palette.inkSecondary),
            title: Text(dish.name),
            subtitle: Text([
              per100Line(aContext, dish.per100),
              if (dish.portionG != null) 'nutrition.portion_is'.tr(args: [formatGrams(aContext, dish.portionG!)]),
              if (dish.ownerName != null) dish.ownerName!,
            ].join(' · ')),
            trailing: Icon(AppIcons.plus, color: aContext.colors.primary),
          ),
        ListTile(
          onTap: _newDish,
          leading: Icon(AppIcons.plusCircle, color: aContext.colors.primary),
          title: Text('nutrition.new_dish'.tr()),
        ),
      ],
    );
  }

  Widget _quickField(TextEditingController aCtrl, String aLabelKey, {double aWidth = 140})
  {
    return SizedBox(
      width: aWidth,
      child: TextField(
        controller: aCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: aLabelKey.tr(), border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  Widget _quickTab(BuildContext aContext)
  {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text('nutrition.quick_hint'.tr(), style: TextStyle(color: aContext.palette.inkSecondary)),
        const SizedBox(height: 16),
        TextField(
          controller: _quickTitle,
          inputFormatters: [LengthLimitingTextInputFormatter(_maxTitleLen)],
          decoration: InputDecoration(labelText: 'nutrition.quick_name'.tr(), border: const OutlineInputBorder(), isDense: true),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _quickField(_quickKcal, 'nutrition.kcal_required'),
            _quickField(_quickProt, 'items.prot'),
            _quickField(_quickFat, 'items.fat'),
            _quickField(_quickCarb, 'items.carb'),
          ],
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton.icon(
            onPressed: _isQuickValid && !_isBusy ? _addQuick : null,
            icon: const Icon(AppIcons.plus, size: 18),
            label: Text('nutrition.add'.tr()),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final meals = _meals;
    final target = _target;
    final people = ref.watch(peopleProv).valueOrNull ?? const <PersonRef>[];
    final person = people.where((aPerson) => aPerson.id == widget.personId).firstOrNull;
    final title = 'nutrition.add_title'.tr(args: [DateFormat.MMMd(aContext.locale.toLanguageTag()).format(widget.date)]);

    return DefaultTabController(
      length: 3,
      child: SubPage(
        title: person == null ? title : '$title · ${person.fullName}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: meals == null || target == null
                  ? const LinearProgressIndicator()
                  : MealTargetPicker(
                      date: widget.date,
                      meals: meals,
                      value: target,
                      isEnabled: !_isBusy,
                      onChanged: (aTarget) => setState(() => _target = aTarget),
                    ),
            ),
            TabBar(
              tabs: [
                Tab(text: 'nutrition.tab_products'.tr()),
                Tab(text: 'nutrition.tab_dishes'.tr()),
                Tab(text: 'nutrition.tab_quick'.tr()),
              ],
            ),
            Expanded(
              child: Builder(
                builder: (aTabContext) => SnapTabView(
                  controller: DefaultTabController.of(aTabContext),
                  children: [
                    FoodSearchPanel(onPick: (aItem) => _pickItem(aItem), idleChildren: [_recentSection(aContext)]),
                    _dishesTab(aContext),
                    _quickTab(aContext),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
