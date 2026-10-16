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
import 'amount_sheet.dart';
import 'nutrition_format.dart';
import 'nutrition_summary.dart';

const double _contentMaxWidth = 720;
const int _maxFutureDays = 7;
const double _maxQuickKcal = 10000;
const double _maxQuickGrams = 1000;

String addFoodPath(DateTime aDate, MealSlot aMeal) =>
    Uri(path: '/app/nutrition/add', queryParameters: {'date': dateWire(aDate), 'meal': aMeal.name}).toString();

class NutritionDiaryScreen extends ConsumerStatefulWidget
{
  final DateTime? initialDate;

  const NutritionDiaryScreen({super.key, this.initialDate});

  @override
  ConsumerState<NutritionDiaryScreen> createState() => _NutritionDiaryScreenState();
}

class _NutritionDiaryScreenState extends ConsumerState<NutritionDiaryScreen>
{
  late DateTime _date = dayOnly(widget.initialDate ?? DateTime.now());
  NutritionDay? _day;
  Object? _error;
  bool _isBusy = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    final date = _date;
    try
    {
      final day = await ref.read(apiProv).getNutritionDay(date);
      if (mounted && date == _date)
      {
        setState(()
        {
          _day = day;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted && date == _date)
      {
        setState(() => _error = aError);
      }
    }
  }

  DateTime get _lastDate => dayOnly(DateTime.now()).add(const Duration(days: _maxFutureDays));

  void _setDate(DateTime aDate)
  {
    final date = dayOnly(aDate);
    if (date.isAfter(_lastDate))
    {
      return;
    }
    setState(()
    {
      _date = date;
      _day = null;
      _error = null;
    });
    _load();
  }

  Future<void> _pickDate() async
  {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2016),
      lastDate: _lastDate,
    );
    if (picked != null && mounted)
    {
      _setDate(picked);
    }
  }

  Future<void> _add(MealSlot aMeal) async
  {
    await context.push(addFoodPath(_date, aMeal));
    await _load();
  }

  Future<void> _copyFromYesterday({MealSlot? aMeal}) async
  {
    setState(() => _isBusy = true);
    try
    {
      final copied = await ref.read(apiProv).copyMeals(_date.subtract(const Duration(days: 1)), _date, aMeal: aMeal);
      if (!mounted)
      {
        return;
      }
      showInfoSnack(context, copied == 0 ? 'nutrition.copy_none'.tr() : 'nutrition.copied'.plural(copied));
      if (copied > 0)
      {
        notifyNutritionChanged(ref);
        await _load();
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
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _apply(Future<void> Function() aAction) async
  {
    try
    {
      await aAction();
      if (mounted)
      {
        notifyNutritionChanged(ref);
        await _load();
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

  Future<void> _edit(MealEntry aEntry) async
  {
    final api = ref.read(apiProv);
    if (aEntry.source == MealSource.quick)
    {
      final result = await showDialog<_QuickEdit>(context: context, builder: (_) => _QuickEditDialog(entry: aEntry));
      if (result == null || !mounted)
      {
        return;
      }
      await _apply(() => result.isDelete
          ? api.deleteMealEntry(aEntry.id)
          : api.updateMealEntry(aEntry.id, {'date': dateWire(_date), 'meal': result.meal.name, 'quick': result.quick}));
      return;
    }

    final result = await showAmountSheet(
      context,
      aTarget: AmountTarget.entry(aEntry),
      aMeal: aEntry.meal,
      aGrams: aEntry.portions == null ? aEntry.grams : null,
      aPortions: aEntry.portions,
      aIsEdit: true,
    );
    if (result == null || !mounted)
    {
      return;
    }
    await _apply(() => result.isDelete
        ? api.deleteMealEntry(aEntry.id)
        : api.updateMealEntry(aEntry.id, {'date': dateWire(_date), ...result.toJson()}));
  }

  Widget _dateBar(BuildContext aContext)
  {
    final isLast = !_date.isBefore(_lastDate);
    final isToday = _date == dayOnly(DateTime.now());
    return Row(
      children: [
        IconButton(
          tooltip: 'nutrition.prev_day'.tr(),
          onPressed: () => _setDate(_date.subtract(const Duration(days: 1))),
          icon: const Icon(AppIcons.chevronLeft),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: _pickDate,
            icon: const Icon(AppIcons.calendar, size: 18),
            label: Text(dayTitle(aContext, _date), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (!isToday)
          TextButton(onPressed: () => _setDate(DateTime.now()), child: Text('nutrition.today'.tr())),
        IconButton(
          tooltip: 'nutrition.next_day'.tr(),
          onPressed: isLast ? null : () => _setDate(_date.add(const Duration(days: 1))),
          icon: const Icon(AppIcons.chevronRight),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(nutritionRevisionProv, (_, __) => _load());
    final day = _day;
    final Widget body;
    if (_error != null)
    {
      body = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (day == null)
    {
      body = const Center(child: CircularProgressIndicator());
    }
    else
    {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: screenPadding(aContext),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(padding: const EdgeInsets.all(16), child: NutritionSummary(day: day)),
                    ),
                    const SizedBox(height: 16),
                    for (final meal in MealSlot.values) ...[
                      _MealSection(
                        group: day.group(meal),
                        onAdd: () => _add(meal),
                        onEdit: _edit,
                        onCopy: _isBusy ? null : () => _copyFromYesterday(aMeal: meal),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return SubPage(
      title: 'nutrition.title'.tr(),
      actions: [
        IconButton(tooltip: 'nutrition.dishes'.tr(), onPressed: () => aContext.push('/app/dishes'), icon: const Icon(AppIcons.cookingPot)),
        PopupMenuButton<String>(
          tooltip: 'common.actions'.tr(),
          icon: const Icon(AppIcons.moreVertical),
          onSelected: (_) => _copyFromYesterday(),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'copy', enabled: !_isBusy, child: Text('nutrition.copy_day'.tr())),
          ],
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _dateBar(aContext)),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _MealSection extends StatelessWidget
{
  final MealGroup group;
  final VoidCallback onAdd;
  final ValueChanged<MealEntry> onEdit;
  final VoidCallback? onCopy;

  const _MealSection({required this.group, required this.onAdd, required this.onEdit, this.onCopy});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final hasEntries = group.entries.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'nutrition.add_to'.tr(args: [mealLabel(group.meal)]),
                  onPressed: onAdd,
                  icon: Icon(AppIcons.plus, color: aContext.colors.primary),
                ),
                Icon(mealIcon(group.meal), size: 18, color: palette.inkSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(mealLabel(group.meal), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                if (hasEntries)
                  Text(formatKcal(aContext, group.total.kcal), style: const TextStyle(fontWeight: FontWeight.w700)),
                PopupMenuButton<String>(
                  tooltip: 'common.actions'.tr(),
                  icon: const Icon(AppIcons.moreVertical, size: 18),
                  onSelected: (_) => onCopy?.call(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'copy', enabled: onCopy != null, child: Text('nutrition.copy_meal'.tr())),
                  ],
                ),
              ],
            ),
            if (!hasEntries)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('nutrition.meal_empty'.tr(), style: TextStyle(color: palette.inkMuted)),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(macrosLine(aContext, group.total), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
              ),
              for (final entry in group.entries)
                ListTile(
                  dense: true,
                  onTap: () => onEdit(entry),
                  title: Text(entryTitle(entry), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (entryAmount(aContext, entry).isNotEmpty) entryAmount(aContext, entry),
                      macrosLine(aContext, entry.total),
                    ].join(' · '),
                  ),
                  trailing: Text(formatKcal(aContext, entry.total.kcal), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuickEdit
{
  final MealSlot meal;
  final Map<String, dynamic>? quick;
  final bool isDelete;

  const _QuickEdit({required this.meal, this.quick, this.isDelete = false});
}

class _QuickEditDialog extends StatefulWidget
{
  final MealEntry entry;

  const _QuickEditDialog({required this.entry});

  @override
  State<_QuickEditDialog> createState() => _QuickEditDialogState();
}

class _QuickEditDialogState extends State<_QuickEditDialog>
{
  late MealSlot _meal = widget.entry.meal;
  late final _title = TextEditingController(text: widget.entry.title ?? '');
  late final _kcal = TextEditingController(text: amountText(widget.entry.total.kcal));
  late final _prot = TextEditingController(text: amountText(widget.entry.total.prot));
  late final _fat = TextEditingController(text: amountText(widget.entry.total.fat));
  late final _carb = TextEditingController(text: amountText(widget.entry.total.carb));

  @override
  void dispose()
  {
    for (final ctrl in [_title, _kcal, _prot, _fat, _carb])
    {
      ctrl.dispose();
    }
    super.dispose();
  }

  bool get _isValid
  {
    final kcal = parseAmountText(_kcal.text);
    if (kcal == null || kcal < 0 || kcal > _maxQuickKcal)
    {
      return false;
    }
    return [_prot, _fat, _carb].every((aCtrl)
    {
      final value = parseAmountText(aCtrl.text);
      return aCtrl.text.trim().isEmpty || (value != null && value >= 0 && value <= _maxQuickGrams);
    });
  }

  Widget _field(TextEditingController aCtrl, String aLabelKey)
  {
    return SizedBox(
      width: 120,
      child: TextField(
        controller: aCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: aLabelKey.tr(), border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  void _save()
  {
    String? wire(TextEditingController aCtrl) => parseAmountText(aCtrl.text)?.toString();
    final title = _title.text.trim();
    Navigator.of(context).pop(_QuickEdit(
      meal: _meal,
      quick: {
        'title': title.isEmpty ? null : title,
        'kcal': wire(_kcal),
        'prot': wire(_prot),
        'fat': wire(_fat),
        'carb': wire(_carb),
      },
    ));
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      scrollable: true,
      title: Text('nutrition.quick_title'.tr()),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              decoration: InputDecoration(labelText: 'nutrition.quick_name'.tr(), border: const OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _field(_kcal, 'nutrition.kcal_required'),
                _field(_prot, 'items.prot'),
                _field(_fat, 'items.fat'),
                _field(_carb, 'items.carb'),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final meal in MealSlot.values)
                  ChoiceChip(
                    label: Text(mealLabel(meal)),
                    selected: _meal == meal,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _meal = meal),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: aContext.palette.danger),
          onPressed: () => Navigator.of(aContext).pop(_QuickEdit(meal: _meal, isDelete: true)),
          child: Text('common.delete'.tr()),
        ),
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: _isValid ? _save : null, child: Text('common.save'.tr())),
      ],
    );
  }
}
