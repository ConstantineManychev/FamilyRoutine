import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import 'exercises_screen.dart';

const List<String> exerciseTypes = ['cardio', 'strength', 'flexibility', 'mixed'];
const List<String> weightTypes = ['external', 'hybrid', 'bodyweight'];
const double minMet = 0.5;
const double maxMet = 30.0;

class _MuscleRow
{
  final int key;
  MuscGrpType grp;
  final TextEditingController pctCtrl;

  _MuscleRow(this.key, this.grp, double aPct) : pctCtrl = TextEditingController(text: _formatPct(aPct));

  static String _formatPct(double aPct) => aPct == aPct.roundToDouble() ? aPct.toInt().toString() : aPct.toString();
}

class ExerciseDetailScreen extends ConsumerStatefulWidget
{
  final String? exId;

  const ExerciseDetailScreen({super.key, this.exId});

  @override
  ConsumerState<ExerciseDetailScreen> createState() => _ExerciseDetailScreenState();
}

class _ExerciseDetailScreenState extends ConsumerState<ExerciseDetailScreen>
{
  final _nameCtrl = TextEditingController();
  final _metCtrl = TextEditingController();
  final _bwPctCtrl = TextEditingController(text: '0');
  final List<_MuscleRow> _muscles = [];

  String _selType = 'strength';
  String _selWeightType = 'external';
  bool _isCustom = true;
  bool _isLoading = false;
  bool _isSaving = false;
  Object? _loadError;
  int _nextRowKey = 0;

  bool get _isEdit => widget.exId != null;
  bool get _isEditable => !_isEdit || _isCustom;

  @override
  void initState()
  {
    super.initState();
    if (_isEdit)
    {
      _initData();
    }
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    _metCtrl.dispose();
    _bwPctCtrl.dispose();
    for (final row in _muscles)
    {
      row.pctCtrl.dispose();
    }
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
      final ex = await ref.read(apiProv).getExercise(widget.exId!);
      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _nameCtrl.text = ex.name;
        _metCtrl.text = ex.metVal.toString();
        _selType = ex.exType;
        _selWeightType = ex.weightType;
        _bwPctCtrl.text = ex.bwPct.toString();
        _isCustom = ex.isCustom;
        _muscles
          ..clear()
          ..addAll(ex.muscGrps.map((aGrp) => _MuscleRow(_nextRowKey++, aGrp.grp, aGrp.pct)));
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isLoading = false);
      }
    }
  }

  void _addMuscleRow()
  {
    final used = _muscles.map((aRow) => aRow.grp).toSet();
    final free = MuscGrpType.values.where((aGrp) => !used.contains(aGrp)).firstOrNull;
    if (free == null)
    {
      return;
    }

    setState(() => _muscles.add(_MuscleRow(_nextRowKey++, free, 100)));
  }

  void _removeMuscleRow(_MuscleRow aRow)
  {
    setState(() => _muscles.remove(aRow));
    aRow.pctCtrl.dispose();
  }

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'exercises.edit'.tr(),
      aMessage: 'common.delete_confirm'.tr(),
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    setState(() => _isSaving = true);

    try
    {
      await ref.read(apiProv).deleteExercise(widget.exId!);
      ref.invalidate(exercisesProv);
      if (mounted)
      {
        context.go('/app/exercises');
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

  String? _validationKey(double? aMet, double aBwPct, List<ExMuscGrpDto> aGroups)
  {
    if (_nameCtrl.text.trim().isEmpty)
    {
      return 'validation.required';
    }
    if (aMet == null || aMet < minMet || aMet > maxMet)
    {
      return 'exercises.err_met';
    }
    if (aBwPct < 0 || aBwPct > 100)
    {
      return 'exercises.err_bw_pct';
    }
    if (aGroups.isEmpty)
    {
      return 'exercises.err_no_muscles';
    }
    if (aGroups.any((aGroup) => aGroup.pct <= 0 || aGroup.pct > 100))
    {
      return 'exercises.err_pct';
    }
    if (aGroups.map((aGroup) => aGroup.grp).toSet().length != aGroups.length)
    {
      return 'exercises.err_duplicate_grp';
    }
    return null;
  }

  Future<void> _save() async
  {
    FocusScope.of(context).unfocus();

    final met = double.tryParse(_metCtrl.text.trim().replaceAll(',', '.'));
    final bwPct = _selWeightType == 'external' ? 0.0 : double.tryParse(_bwPctCtrl.text.trim()) ?? -1;
    final groups = _muscles
        .map((aRow) => ExMuscGrpDto(grp: aRow.grp, pct: double.tryParse(aRow.pctCtrl.text.trim()) ?? 0))
        .toList();

    final errorKey = _validationKey(met, bwPct, groups);
    if (errorKey != null)
    {
      showInfoSnack(context, errorKey.tr());
      return;
    }

    setState(() => _isSaving = true);

    final payload = {
      'name': _nameCtrl.text.trim(),
      'ex_type': _selType,
      'met_val': met,
      'weight_type': _selWeightType,
      'bw_pct': bwPct,
      'musc_grps': groups.map((aGroup) => aGroup.toJson()).toList(),
    };

    try
    {
      final api = ref.read(apiProv);
      if (_isEdit)
      {
        await api.updateExercise(widget.exId!, payload);
      }
      else
      {
        await api.createExercise(payload);
      }

      ref.invalidate(exercisesProv);
      if (mounted)
      {
        context.go('/app/exercises');
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

    final isBwVisible = _selWeightType == 'hybrid' || _selWeightType == 'bodyweight';

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'exercises.edit'.tr() : 'exercises.add'.tr(),
          actions: [
            if (_isEdit && _isEditable)
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(LucideIcons.trash, color: Colors.red, size: 18),
                label: Text('common.delete'.tr()),
              ),
            if (_isEditable)
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(LucideIcons.save, size: 18),
                label: Text('common.save'.tr()),
              ),
          ],
        ),
        if (!_isEditable) ...[
          const SizedBox(height: 12),
          Text('exercises.system_read_only'.tr(), style: const TextStyle(color: Colors.grey)),
        ],
        const SizedBox(height: 24),
        TextField(
          controller: _nameCtrl,
          enabled: _isEditable,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          decoration: _decoration('exercises.name'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _selType,
                decoration: _decoration('exercises.type'),
                items: exerciseTypes
                    .map((aType) => DropdownMenuItem(value: aType, child: Text('exercises.types.$aType'.tr())))
                    .toList(),
                onChanged: _isEditable ? (aValue) => setState(() => _selType = aValue ?? _selType) : null,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _metCtrl,
                enabled: _isEditable,
                decoration: _decoration('exercises.met'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                initialValue: _selWeightType,
                decoration: _decoration('exercises.weight_type'),
                items: weightTypes
                    .map((aType) => DropdownMenuItem(value: aType, child: Text('exercises.w_types.$aType'.tr())))
                    .toList(),
                onChanged: _isEditable
                    ? (aValue)
                    {
                      setState(()
                      {
                        _selWeightType = aValue ?? _selWeightType;
                        if (_selWeightType == 'external')
                        {
                          _bwPctCtrl.text = '0';
                        }
                        if (_selWeightType == 'bodyweight')
                        {
                          _bwPctCtrl.text = '100';
                        }
                      });
                    }
                    : null,
              ),
            ),
            if (isBwVisible) ...[
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _bwPctCtrl,
                  enabled: _isEditable,
                  decoration: _decoration('exercises.bw_pct'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('exercises.muscles'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (_isEditable)
              TextButton.icon(
                onPressed: _muscles.length < MuscGrpType.values.length ? _addMuscleRow : null,
                icon: const Icon(LucideIcons.plus),
                label: Text('exercises.add_muscle'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (final row in _muscles) _buildMuscleRow(row),
      ],
    );
  }

  Widget _buildMuscleRow(_MuscleRow aRow)
  {
    return Padding(
      key: ValueKey(aRow.key),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<MuscGrpType>(
              initialValue: aRow.grp,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: MuscGrpType.values
                  .map((aGrp) => DropdownMenuItem(
                        value: aGrp,
                        child: Text('exercises.muscle_grps.${aGrp.wireName}'.tr()),
                      ))
                  .toList(),
              onChanged: _isEditable ? (aGrp) => setState(() => aRow.grp = aGrp ?? aRow.grp) : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: aRow.pctCtrl,
              enabled: _isEditable,
              decoration: _decoration('exercises.pct'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ),
          if (_isEditable)
            IconButton(
              tooltip: 'common.delete'.tr(),
              icon: const Icon(LucideIcons.trash, color: Colors.red),
              onPressed: () => _removeMuscleRow(aRow),
            ),
        ],
      ),
    );
  }
}
