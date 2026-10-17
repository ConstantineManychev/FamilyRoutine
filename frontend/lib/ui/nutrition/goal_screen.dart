import 'dart:async';

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
import 'nutrition_format.dart';
import 'nutrition_summary.dart';

const double _contentMaxWidth = 720;
const Duration _previewDelay = Duration(milliseconds: 350);
const List<double> losePaces = [0.25, 0.5, 0.75, 1];
const List<double> gainPaces = [0.2, 0.3, 0.45];
const double _kcalPerGramProt = 4;
const double _kcalPerGramFat = 9;
const double _kcalPerGramCarb = 4;
const double _percentTolerance = 0.5;
const double minCustomKcal = 800;
const double maxCustomKcal = 6000;
const double _maxCustomProt = 600;
const double _maxCustomFat = 400;
const double _maxCustomCarb = 1000;

List<double> pacesFor(GoalMode aMode) => aMode == GoalMode.gain ? gainPaces : losePaces;

double defaultPace(GoalMode aMode) => aMode == GoalMode.gain ? 0.3 : 0.5;

Macros? customFromInputs({
  required double? aKcal,
  required double? aProt,
  required double? aFat,
  required double? aCarb,
  required bool aIsPercent,
})
{
  if (aKcal == null || aProt == null || aFat == null || aCarb == null || aKcal < minCustomKcal || aKcal > maxCustomKcal)
  {
    return null;
  }
  if (aIsPercent && (aProt + aFat + aCarb - 100).abs() > _percentTolerance)
  {
    return null;
  }
  final macros = aIsPercent
      ? Macros(
          kcal: aKcal,
          prot: (aKcal * aProt / 100 / _kcalPerGramProt).roundToDouble(),
          fat: (aKcal * aFat / 100 / _kcalPerGramFat).roundToDouble(),
          carb: (aKcal * aCarb / 100 / _kcalPerGramCarb).roundToDouble(),
        )
      : Macros(kcal: aKcal, prot: aProt, fat: aFat, carb: aCarb);
  final isInRange = macros.prot <= _maxCustomProt && macros.fat <= _maxCustomFat && macros.carb <= _maxCustomCarb;
  return isInRange ? macros : null;
}

List<double> macroPercents(Macros aMacros)
{
  final kcal = aMacros.kcal;
  if (kcal <= 0)
  {
    return const [0, 0, 0];
  }
  return [
    aMacros.prot * _kcalPerGramProt / kcal * 100,
    aMacros.fat * _kcalPerGramFat / kcal * 100,
    aMacros.carb * _kcalPerGramCarb / kcal * 100,
  ];
}

class GoalScreen extends ConsumerStatefulWidget
{
  final String? personId;

  const GoalScreen({super.key, this.personId});

  @override
  ConsumerState<GoalScreen> createState() => _GoalScreenState();
}

class _GoalScreenState extends ConsumerState<GoalScreen>
{
  final _targetCtrl = TextEditingController();
  final _kcalCtrl = TextEditingController();
  final _protCtrl = TextEditingController();
  final _fatCtrl = TextEditingController();
  final _carbCtrl = TextEditingController();

  NutritionGoal? _saved;
  NutritionGoal? _preview;
  GoalDraft _draft = const GoalDraft();
  Object? _error;
  Timer? _debounce;
  int _previewId = 0;
  bool _isPercent = false;
  bool _isBusy = false;
  bool _isDirty = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _debounce?.cancel();
    for (final ctrl in [_targetCtrl, _kcalCtrl, _protCtrl, _fatCtrl, _carbCtrl])
    {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async
  {
    try
    {
      final goal = await ref.read(apiProv).getNutritionGoal(aPersonId: widget.personId);
      if (!mounted)
      {
        return;
      }
      setState(()
      {
        _saved = goal;
        _preview = goal;
        _draft = GoalDraft.of(goal);
        _error = null;
        _targetCtrl.text = amountText(goal.targetKg);
        _fillCustom(goal.custom ?? goal.norm?.target);
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _fillCustom(Macros? aMacros)
  {
    if (aMacros == null)
    {
      return;
    }
    _kcalCtrl.text = amountText(aMacros.kcal.roundToDouble());
    if (_isPercent)
    {
      final percents = macroPercents(aMacros);
      _protCtrl.text = amountText(percents[0].roundToDouble());
      _fatCtrl.text = amountText(percents[1].roundToDouble());
      _carbCtrl.text = amountText((100 - percents[0].roundToDouble() - percents[1].roundToDouble()).clamp(0, 100).toDouble());
    }
    else
    {
      _protCtrl.text = amountText(aMacros.prot.roundToDouble());
      _fatCtrl.text = amountText(aMacros.fat.roundToDouble());
      _carbCtrl.text = amountText(aMacros.carb.roundToDouble());
    }
  }

  Macros? get _customInput => customFromInputs(
        aKcal: parseAmountText(_kcalCtrl.text),
        aProt: parseAmountText(_protCtrl.text),
        aFat: parseAmountText(_fatCtrl.text),
        aCarb: parseAmountText(_carbCtrl.text),
        aIsPercent: _isPercent,
      );

  bool get _isCustomValid => !_draft.isCustom || _customInput != null;

  void _change(GoalDraft aDraft)
  {
    setState(()
    {
      _draft = aDraft;
      _isDirty = true;
    });
    _schedulePreview();
  }

  void _schedulePreview()
  {
    _debounce?.cancel();
    if (!_isCustomValid)
    {
      return;
    }
    _debounce = Timer(_previewDelay, _runPreview);
  }

  Future<void> _runPreview() async
  {
    final previewId = ++_previewId;
    try
    {
      final preview = await ref.read(apiProv).previewNutritionGoal(_draft, aPersonId: widget.personId);
      if (mounted && previewId == _previewId)
      {
        setState(() => _preview = preview);
      }
    }
    catch (_)
    {
      if (mounted && previewId == _previewId)
      {
        setState(() => _preview = null);
      }
    }
  }

  void _setMode(GoalMode aMode)
  {
    final paces = pacesFor(aMode);
    final pace = _draft.paceKg;
    _change(_draft.copyWith(mode: aMode, paceKg: pace != null && paces.contains(pace) ? pace : defaultPace(aMode)));
  }

  void _setTarget(String aText)
  {
    final value = parseAmountText(aText);
    _change(value == null ? _draft.copyWith(isTargetCleared: true) : _draft.copyWith(targetKg: value));
  }

  void _setCustom(bool aIsCustom)
  {
    if (aIsCustom && parseAmountText(_kcalCtrl.text) == null)
    {
      _fillCustom(_preview?.norm?.target);
    }
    _change(_draft.copyWith(isCustom: aIsCustom, custom: _customInput));
  }

  void _setPercent(bool aIsPercent)
  {
    final current = _customInput;
    setState(()
    {
      _isPercent = aIsPercent;
      _fillCustom(current);
    });
  }

  void _customChanged()
  {
    final custom = _customInput;
    if (custom == null)
    {
      setState(() => _isDirty = true);
      return;
    }
    _change(_draft.copyWith(custom: custom));
  }

  Future<void> _save() async
  {
    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).saveNutritionGoal(_draft, aPersonId: widget.personId);
      if (!mounted)
      {
        return;
      }
      notifyNutritionChanged(ref);
      showInfoSnack(context, 'goal.saved'.tr());
      closePage(context);
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

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final saved = _saved;
    final Widget body;
    if (saved == null)
    {
      body = _error != null ? ErrorRetry(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator());
    }
    else
    {
      body = ListView(
        padding: screenPadding(aContext),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (saved.isChild) _childIntro(aContext) else _adultControls(aContext),
                  const SizedBox(height: 16),
                  GoalResultCard(goal: _preview),
                  if (!saved.isChild) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        key: const ValueKey('goal.save'),
                        onPressed: _isDirty && _isCustomValid && !_isBusy ? _save : null,
                        icon: const Icon(AppIcons.save, size: 18),
                        label: Text('common.save'.tr()),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }

    final people = ref.watch(peopleProv).valueOrNull ?? const <PersonRef>[];
    final person = people.where((aPerson) => aPerson.id == widget.personId).firstOrNull;
    return SubPage(title: person == null ? 'goal.title'.tr() : '${'goal.title'.tr()} · ${person.fullName}', child: body);
  }

  Widget _childIntro(BuildContext aContext)
  {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.shieldCheck, color: aContext.palette.positive),
            const SizedBox(width: 12),
            Expanded(child: Text('goal.child_intro'.tr(), style: TextStyle(color: aContext.palette.inkSecondary))),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext aContext, String aTitle)
  {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(aTitle, style: TextStyle(fontWeight: FontWeight.w700, color: aContext.palette.inkSecondary)),
    );
  }

  Widget _numberField(TextEditingController aCtrl, String aLabel, {String? aSuffix, ValueChanged<String>? aOnChanged, Key? aKey})
  {
    return SizedBox(
      width: 130,
      child: TextField(
        key: aKey,
        controller: aCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(6)],
        onChanged: aOnChanged ?? (_) => _customChanged(),
        decoration: InputDecoration(labelText: aLabel, suffixText: aSuffix, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  Widget _adultControls(BuildContext aContext)
  {
    final palette = aContext.palette;
    final draft = _draft;
    final custom = _customInput;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _section(aContext, 'goal.goal'.tr()),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in GoalMode.values)
                  ChoiceChip(
                    key: ValueKey('goal.mode.${mode.name}'),
                    showCheckmark: false,
                    avatar: Icon(
                      switch (mode)
                      {
                        GoalMode.lose => AppIcons.arrowDown,
                        GoalMode.maintain => AppIcons.scale,
                        GoalMode.gain => AppIcons.arrowUp,
                      },
                      size: 16,
                    ),
                    label: Text(goalModeLabel(mode)),
                    selected: draft.mode == mode,
                    onSelected: _isBusy ? null : (_) => _setMode(mode),
                  ),
              ],
            ),
            if (draft.mode != GoalMode.maintain) ...[
              _section(aContext, 'goal.pace'.tr()),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final pace in pacesFor(draft.mode))
                    ChoiceChip(
                      key: ValueKey('goal.pace.$pace'),
                      showCheckmark: false,
                      label: Text(paceText(aContext, pace)),
                      selected: draft.paceKg == pace,
                      onSelected: _isBusy ? null : (_) => _change(draft.copyWith(paceKg: pace)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text('goal.pace_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 280,
                  child: TextField(
                    key: const ValueKey('goal.target'),
                    controller: _targetCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(5)],
                    onChanged: _setTarget,
                    decoration: InputDecoration(
                      labelText: 'goal.target_kg'.tr(),
                      suffixText: 'goal.kg'.tr(),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('goal.custom'),
              contentPadding: EdgeInsets.zero,
              title: Text('goal.custom'.tr()),
              subtitle: Text('goal.custom_hint'.tr()),
              value: draft.isCustom,
              onChanged: _isBusy ? null : _setCustom,
            ),
            if (draft.isCustom) ...[
              const SizedBox(height: 4),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text('goal.in_grams'.tr())),
                  ButtonSegment(value: true, label: Text('goal.in_percent'.tr())),
                ],
                selected: {_isPercent},
                showSelectedIcon: false,
                onSelectionChanged: (aSelected) => _setPercent(aSelected.first),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _numberField(_kcalCtrl, 'nutrition.kcal_short'.tr(), aSuffix: 'nutrition.kcal_unit'.tr(), aKey: const ValueKey('goal.custom.kcal')),
                  _numberField(_protCtrl, 'nutrition.prot'.tr(), aSuffix: _isPercent ? '%' : 'nutrition.g_unit'.tr(), aKey: const ValueKey('goal.custom.prot')),
                  _numberField(_fatCtrl, 'nutrition.fat'.tr(), aSuffix: _isPercent ? '%' : 'nutrition.g_unit'.tr(), aKey: const ValueKey('goal.custom.fat')),
                  _numberField(_carbCtrl, 'nutrition.carb'.tr(), aSuffix: _isPercent ? '%' : 'nutrition.g_unit'.tr(), aKey: const ValueKey('goal.custom.carb')),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                custom == null
                    ? (_isPercent ? 'goal.percent_sum'.tr() : 'goal.custom_invalid'.tr())
                    : _isPercent
                        ? macrosLine(aContext, custom)
                        : 'goal.macros_kcal'.tr(args: [
                            formatAmount(
                              aContext,
                              custom.prot * _kcalPerGramProt + custom.fat * _kcalPerGramFat + custom.carb * _kcalPerGramCarb,
                              aDigits: 0,
                            ),
                          ]),
                style: TextStyle(fontSize: 12, color: custom == null ? palette.danger : palette.inkMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class GoalResultCard extends StatelessWidget
{
  final NutritionGoal? goal;

  const GoalResultCard({super.key, required this.goal});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final norm = goal?.norm;
    final gaps = goal?.normGaps ?? const <NormGap>[];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: norm == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('nutrition.no_norm'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  if (gaps.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(normGapText(gaps), style: TextStyle(color: palette.inkSecondary)),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: () => aContext.push('/app/profile'), child: Text('nutrition.open_profile'.tr())),
                    ),
                  ],
                ],
              )
            : NormDetails(norm: norm),
      ),
    );
  }
}

class NormDetails extends StatelessWidget
{
  final NutritionNorm norm;

  const NormDetails({super.key, required this.norm});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final target = norm.target;
    final percents = macroPercents(target);
    final weeks = norm.weeksToTarget;
    final targetKg = norm.targetKg;

    Widget macro(String aLabel, double aGrams, double aPercent) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(aLabel, style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
              Text(
                '${formatAmount(aContext, aGrams, aDigits: 0)} ${'nutrition.g_unit'.tr()}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text('${formatAmount(aContext, aPercent, aDigits: 0)} %', style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(normHeadline(aContext, norm), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
        const SizedBox(height: 4),
        Text.rich(
          key: const ValueKey('goal.result.kcal'),
          TextSpan(children: [
            TextSpan(
              text: formatAmount(aContext, target.kcal, aDigits: 0),
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: palette.inkPrimary),
            ),
            TextSpan(text: ' ${'goal.kcal_per_day'.tr()}', style: TextStyle(color: palette.inkSecondary)),
          ]),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            macro('nutrition.prot'.tr(), target.prot, percents[0]),
            macro('nutrition.fat'.tr(), target.fat, percents[1]),
            macro('nutrition.carb'.tr(), target.carb, percents[2]),
          ],
        ),
        for (final warning in norm.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.alertCircle, size: 16, color: palette.warning),
                const SizedBox(width: 6),
                Expanded(child: Text(normWarningText(aContext, warning, norm), style: TextStyle(color: palette.warning))),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Text(normBasis(aContext, norm), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
        if (norm.floorKcal != null && norm.kind != NormKind.child)
          Text(
            'goal.floor_line'.tr(args: [formatAmount(aContext, norm.floorKcal!, aDigits: 0)]),
            style: TextStyle(fontSize: 12, color: palette.inkMuted),
          ),
        if (weeks != null && targetKg != null)
          Text(
            'goal.weeks_line'.tr(args: [formatAmount(aContext, targetKg), '$weeks']),
            key: const ValueKey('goal.result.weeks'),
            style: TextStyle(fontSize: 12, color: palette.inkMuted),
          ),
      ],
    );
  }
}
