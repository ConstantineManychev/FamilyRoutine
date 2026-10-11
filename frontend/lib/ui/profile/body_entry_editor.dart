import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'metric_format.dart';

const double _fieldWidth = 220;
const double _fieldSpacing = 12;
const int _minFieldColumns = 2;
const int _maxNoteLength = 200;

Future<BodyEntry?> showBodyEntryEditor(
  BuildContext aContext,
  {
    required String aPersonId,
    required String aPersonName,
    required List<MetricValue> aLatest,
    BodyEntry? aEntry,
  }
)
{
  return Navigator.of(aContext, rootNavigator: true).push<BodyEntry>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => BodyEntryEditor(personId: aPersonId, personName: aPersonName, latest: aLatest, entry: aEntry),
  ));
}

class BodyEntryEditor extends ConsumerStatefulWidget
{
  final String personId;
  final String personName;
  final List<MetricValue> latest;
  final BodyEntry? entry;

  const BodyEntryEditor({super.key, required this.personId, required this.personName, required this.latest, this.entry});

  @override
  ConsumerState<BodyEntryEditor> createState() => _BodyEntryEditorState();
}

class _BodyEntryEditorState extends ConsumerState<BodyEntryEditor>
{
  final Map<BodyMetric, TextEditingController> _ctrls = {
    for (final metric in BodyMetric.values) metric: TextEditingController(),
  };
  final _noteCtrl = TextEditingController();
  late DateTime _measuredTs;
  final Set<BodyMetric> _invalid = {};
  bool _isSaving = false;
  String? _formError;

  @override
  void initState()
  {
    super.initState();
    final entry = widget.entry;
    _measuredTs = entry?.measuredTs ?? DateTime.now();
    _noteCtrl.text = entry?.note ?? '';
    for (final value in entry?.values ?? const <BodyValue>[])
    {
      _ctrls[value.metric]!.text = _plain(value.value);
    }
  }

  @override
  void dispose()
  {
    for (final ctrl in _ctrls.values)
    {
      ctrl.dispose();
    }
    _noteCtrl.dispose();
    super.dispose();
  }

  String _plain(double aValue) => aValue == aValue.roundToDouble() ? aValue.toStringAsFixed(0) : aValue.toString();

  MetricValue? _latestOf(BodyMetric aMetric)
  {
    for (final value in widget.latest)
    {
      if (value.metric == aMetric)
      {
        return value;
      }
    }
    return null;
  }

  Future<void> _pickTs() async
  {
    final date = await showDatePicker(
      context: context,
      initialDate: _measuredTs,
      firstDate: DateTime(1900),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted)
    {
      return;
    }
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_measuredTs));
    setState(() => _measuredTs = DateTime(date.year, date.month, date.day, time?.hour ?? _measuredTs.hour, time?.minute ?? _measuredTs.minute));
  }

  Future<void> _save() async
  {
    final values = <BodyValue>[];
    final invalid = <BodyMetric>{};
    for (final metric in BodyMetric.values)
    {
      final text = _ctrls[metric]!.text;
      if (text.trim().isEmpty)
      {
        continue;
      }
      final value = parseMetricInput(text);
      if (value == null || !metric.isValid(value))
      {
        invalid.add(metric);
        continue;
      }
      values.add(BodyValue(metric, value));
    }

    setState(()
    {
      _invalid
        ..clear()
        ..addAll(invalid);
      _formError = invalid.isNotEmpty ? 'metrics.err_fix_fields'.tr() : values.isEmpty ? 'metrics.err_empty'.tr() : null;
    });
    if (_formError != null)
    {
      return;
    }

    setState(() => _isSaving = true);
    try
    {
      final note = _noteCtrl.text.trim();
      final saved = await ref.read(apiProv).saveBodyEntry(
            widget.personId,
            widget.entry?.id,
            _measuredTs,
            note.isEmpty ? null : note,
            values,
          );
      if (mounted)
      {
        Navigator.of(context).pop(saved);
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

  Widget _buildField(BodyMetric aMetric, double aWidth)
  {
    final latest = _latestOf(aMetric);
    final isInvalid = _invalid.contains(aMetric);
    final unit = metricUnit(aMetric);

    return SizedBox(
      width: aWidth,
      child: TextField(
        controller: _ctrls[aMetric],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
        onChanged: (_)
        {
          if (isInvalid)
          {
            setState(() => _invalid.remove(aMetric));
          }
        },
        decoration: InputDecoration(
          labelText: metricName(aMetric),
          suffixText: unit.isEmpty ? null : unit,
          helperText: latest == null || widget.entry != null
              ? null
              : 'metrics.was'.tr(args: [formatMetric(context, aMetric, latest.value)]),
          errorText: isInvalid
              ? 'metrics.err_range'.tr(args: [formatMetricNumber(context, aMetric.min), formatMetricNumber(context, aMetric.max)])
              : null,
          errorMaxLines: 2,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildGroup(MetricGroup aGroup, {bool aIsCollapsible = false})
  {
    final metrics = BodyMetric.ofGroup(aGroup);
    final fields = Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: LayoutBuilder(
        builder: (_, aConstraints)
        {
          final columns = math.max(_minFieldColumns, ((aConstraints.maxWidth + _fieldSpacing) / (_fieldWidth + _fieldSpacing)).floor());
          final width = math.min(_fieldWidth, (aConstraints.maxWidth - _fieldSpacing * (columns - 1)) / columns);
          return Wrap(
            spacing: _fieldSpacing,
            runSpacing: _fieldSpacing,
            children: [for (final metric in metrics) _buildField(metric, width)],
          );
        },
      ),
    );

    if (!aIsCollapsible)
    {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(metricGroupName(aGroup), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          fields,
        ],
      );
    }

    final hasValues = metrics.any((aMetric) => _ctrls[aMetric]!.text.isNotEmpty || _invalid.contains(aMetric));
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: hasValues,
        expandedAlignment: Alignment.topLeft,
        title: Text(metricGroupName(aGroup), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        children: [fields],
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? 'metrics.new_entry'.tr() : 'metrics.edit_entry'.tr()),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(AppIcons.save, size: 18),
              label: Text('common.save'.tr()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: screenPadding(aContext),
          children: [
            Text(widget.personName, style: const TextStyle(color: inkSecondary)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickTs,
                  icon: const Icon(AppIcons.calendar, size: 18),
                  label: Text(formatMeasuredTs(aContext, _measuredTs)),
                ),
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _noteCtrl,
                    inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLength)],
                    decoration: InputDecoration(labelText: 'metrics.note'.tr(), border: const OutlineInputBorder(), isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('metrics.entry_hint'.tr(), style: const TextStyle(color: inkSecondary, fontSize: 13)),
            if (_formError != null) ...[
              const SizedBox(height: 8),
              Text(_formError!, style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 16),
            _buildGroup(MetricGroup.body),
            _buildGroup(MetricGroup.composition),
            _buildGroup(MetricGroup.measures, aIsCollapsible: true),
          ],
        ),
      ),
    );
  }
}
