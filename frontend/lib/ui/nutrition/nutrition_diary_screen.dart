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
import '../routine/mark_sheet.dart';
import 'amount_sheet.dart';
import 'meal_target.dart';
import 'nutrition_format.dart';
import 'nutrition_summary.dart';
import '../stock/stock_format.dart';

const double _contentMaxWidth = 720;
const int _maxFutureDays = 7;
const double _maxQuickKcal = 10000;
const double _maxQuickGrams = 1000;

String addFoodPath(DateTime aDate, {String? aMarkId}) => Uri(
      path: '/app/nutrition/add',
      queryParameters: {'date': dateWire(aDate), if (aMarkId != null) 'mark': aMarkId},
    ).toString();

const String goalPath = '/app/nutrition/goal';

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

  Future<void> _add({String? aMarkId}) async
  {
    await context.push(addFoodPath(_date, aMarkId: aMarkId));
    await _load();
  }

  Future<void> _openGoal() async
  {
    await context.push(goalPath);
    await _load();
  }

  Future<void> _openBlock(DayMeal aMeal) async
  {
    await openMarkSheet(context, aMeal.mark.id);
    await _load();
  }

  Future<void> _copyFromYesterday(DayMeal aMeal) async
  {
    setState(() => _isBusy = true);
    try
    {
      final result = await ref.read(apiProv).copyMealFromYesterday(aMeal.mark.id, _date);
      if (!mounted)
      {
        return;
      }
      final copied = result.copied;
      showInfoSnack(context, result.sourceStartTs == null ? 'nutrition.copy_none'.tr() : 'nutrition.copied'.plural(copied));
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

  MealChoice _choiceFor(MealEntry aEntry)
  {
    final meals = _day?.meals ?? const <DayMeal>[];
    return MealChoice(
      date: _date,
      meals: meals,
      initial: defaultMealTarget(_date, meals, aMarkId: aEntry.statusMarkId),
    );
  }

  Future<Map<String, dynamic>> _placement(MealTarget? aTarget) async
  {
    if (aTarget == null)
    {
      return {'date': dateWire(_date)};
    }
    final markId = await ensureMealBlock(ref.read(apiProv), aTarget);
    return {'date': dateWire(_date), 'status_mark_id': markId};
  }

  Future<void> _edit(MealEntry aEntry) async
  {
    final api = ref.read(apiProv);
    if (aEntry.source == MealSource.quick)
    {
      final result = await showDialog<_QuickEdit>(
        context: context,
        builder: (_) => _QuickEditDialog(entry: aEntry, choice: _choiceFor(aEntry)),
      );
      if (result == null || !mounted)
      {
        return;
      }
      await _apply(() async => result.isDelete
          ? api.deleteMealEntry(aEntry.id)
          : api.updateMealEntry(aEntry.id, {...await _placement(result.target), 'quick': result.quick}));
      return;
    }

    final result = await showAmountSheet(
      context,
      aTarget: AmountTarget.entry(aEntry),
      aMealChoice: _choiceFor(aEntry),
      aGrams: aEntry.portions == null ? aEntry.grams : null,
      aPortions: aEntry.portions,
      aIsEdit: true,
    );
    if (result == null || !mounted)
    {
      return;
    }
    await _apply(() async => result.isDelete
        ? api.deleteMealEntry(aEntry.id)
        : api.updateMealEntry(aEntry.id, {...await _placement(result.target), ...result.toJson()}));
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
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: NutritionSummary(day: day, onOpenGoal: _openGoal),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (day.meals.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                        child: Text('nutrition.no_meals'.tr(), style: TextStyle(color: aContext.palette.inkMuted)),
                      ),
                    for (final meal in day.meals) ...[
                      _MealSection(
                        title: mealTitle(aContext, meal),
                        icon: mealIcon(meal.kind),
                        total: meal.total,
                        entries: meal.entries,
                        onAdd: () => _add(aMarkId: meal.mark.id),
                        onEdit: _edit,
                        onCopy: _isBusy ? null : () => _copyFromYesterday(meal),
                        onOpenBlock: () => _openBlock(meal),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (day.unlinked.isNotEmpty) ...[
                      _MealSection(
                        title: 'nutrition.unlinked'.tr(),
                        icon: AppIcons.unlink,
                        total: day.unlinkedTotal,
                        entries: day.unlinked,
                        hint: 'nutrition.unlinked_hint'.tr(),
                        onEdit: _edit,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('nutrition.add_meal'),
                        onPressed: () => _add(),
                        icon: const Icon(AppIcons.plus, size: 18),
                        label: Text('nutrition.add_food'.tr()),
                      ),
                    ),
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
        IconButton(tooltip: 'goal.title'.tr(), onPressed: _openGoal, icon: const Icon(AppIcons.slidersHorizontal)),
        IconButton(tooltip: 'nutrition.dishes'.tr(), onPressed: () => aContext.push('/app/dishes'), icon: const Icon(AppIcons.cookingPot)),
        IconButton(
          key: const ValueKey('diary.stock'),
          tooltip: 'stock.title'.tr(),
          onPressed: () => aContext.push(stockPath),
          icon: const Icon(AppIcons.package),
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
  final String title;
  final IconData icon;
  final Macros total;
  final List<MealEntry> entries;
  final String? hint;
  final VoidCallback? onAdd;
  final ValueChanged<MealEntry> onEdit;
  final VoidCallback? onCopy;
  final VoidCallback? onOpenBlock;

  const _MealSection({
    required this.title,
    required this.icon,
    required this.total,
    required this.entries,
    required this.onEdit,
    this.hint,
    this.onAdd,
    this.onCopy,
    this.onOpenBlock,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final hasEntries = entries.isNotEmpty;
    final add = onAdd;
    final openBlock = onOpenBlock;

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
                if (add != null)
                  IconButton(
                    tooltip: 'nutrition.add_to'.tr(args: [title]),
                    onPressed: add,
                    icon: Icon(AppIcons.plus, color: aContext.colors.primary),
                  )
                else
                  const SizedBox(width: 16),
                Icon(icon, size: 18, color: palette.inkSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                if (hasEntries)
                  Text(formatKcal(aContext, total.kcal), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (openBlock != null)
                  PopupMenuButton<String>(
                    tooltip: 'common.actions'.tr(),
                    icon: const Icon(AppIcons.moreVertical, size: 18),
                    onSelected: (aValue) => aValue == 'copy' ? onCopy?.call() : openBlock(),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'copy', enabled: onCopy != null, child: Text('nutrition.copy_meal'.tr())),
                      PopupMenuItem(value: 'block', child: Text('nutrition.open_block'.tr())),
                    ],
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(hint!, style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ),
            if (!hasEntries)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('nutrition.meal_empty'.tr(), style: TextStyle(color: palette.inkMuted)),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(macrosLine(aContext, total), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
              ),
              for (final entry in entries)
                ListTile(
                  dense: true,
                  onTap: () => onEdit(entry),
                  title: Text(entryTitle(entry), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (entryAmount(aContext, entry).isNotEmpty) entryAmount(aContext, entry),
                      macrosLine(aContext, entry.total),
                      if (entryStockNote(aContext, entry) != null) entryStockNote(aContext, entry)!,
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
  final MealTarget? target;
  final Map<String, dynamic>? quick;
  final bool isDelete;

  const _QuickEdit({this.target, this.quick, this.isDelete = false});
}

class _QuickEditDialog extends StatefulWidget
{
  final MealEntry entry;
  final MealChoice choice;

  const _QuickEditDialog({required this.entry, required this.choice});

  @override
  State<_QuickEditDialog> createState() => _QuickEditDialogState();
}

class _QuickEditDialogState extends State<_QuickEditDialog>
{
  late MealTarget _meal = widget.choice.initial;
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
      target: _meal,
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
            MealTargetPicker(
              date: widget.choice.date,
              meals: widget.choice.meals,
              value: _meal,
              onChanged: (aTarget) => setState(() => _meal = aTarget),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: aContext.palette.danger),
          onPressed: () => Navigator.of(aContext).pop(const _QuickEdit(isDelete: true)),
          child: Text('common.delete'.tr()),
        ),
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: _isValid ? _save : null, child: Text('common.save'.tr())),
      ],
    );
  }
}
