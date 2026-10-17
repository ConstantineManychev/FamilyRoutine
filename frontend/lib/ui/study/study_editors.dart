import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/page_frames.dart';
import '../routine/routine_style.dart';
import 'study_format.dart';

const int maxTopicTitleLen = 200;
const int maxTopicDescriptionLen = 2000;
const int maxStudyNoteLen = 5000;
const double maxStudyGoal = 100000;
const List<double> progressSteps = [1, 5, 10];
const int maxNoteDaysBack = 3650;

double? _parseNumber(String aText)
{
  final text = aText.trim().replaceAll(',', '.').replaceAll(' ', '');
  return text.isEmpty ? null : double.tryParse(text);
}

String _numberText(double aValue) => aValue == aValue.roundToDouble() ? aValue.toStringAsFixed(0) : aValue.toString();

Future<TopicDraft?> showTopicEditor(BuildContext aContext, {StudyTopic? aTopic, String? aParentId})
{
  return showDialog<TopicDraft>(
    context: aContext,
    builder: (_) => TopicEditorDialog(topic: aTopic, parentId: aParentId),
  );
}

class TopicEditorDialog extends StatefulWidget
{
  final StudyTopic? topic;
  final String? parentId;

  const TopicEditorDialog({super.key, this.topic, this.parentId});

  @override
  State<TopicEditorDialog> createState() => _TopicEditorDialogState();
}

class _TopicEditorDialogState extends State<TopicEditorDialog>
{
  late final _titleCtrl = TextEditingController(text: widget.topic?.title ?? '');
  late final _descriptionCtrl = TextEditingController(text: widget.topic?.description ?? '');
  late StudyUnit _unit = widget.topic?.unit ?? StudyUnit.percent;
  late final _targetCtrl = TextEditingController(
    text: widget.topic == null || widget.topic!.unit == StudyUnit.percent ? '' : _numberText(widget.topic!.target),
  );
  late final _doneCtrl = TextEditingController(text: _numberText(widget.topic?.done ?? 0));

  @override
  void dispose()
  {
    for (final ctrl in [_titleCtrl, _descriptionCtrl, _targetCtrl, _doneCtrl])
    {
      ctrl.dispose();
    }
    super.dispose();
  }

  double? get _target => _unit == StudyUnit.percent ? 100 : _parseNumber(_targetCtrl.text);

  double? get _done => _parseNumber(_doneCtrl.text) ?? 0;

  String? get _goalError
  {
    final target = _target;
    final done = _done;
    if (target == null || target <= 0 || target > maxStudyGoal)
    {
      return 'study.err_target'.tr();
    }
    if (done == null || done < 0 || done > (_unit == StudyUnit.percent ? 100 : maxStudyGoal))
    {
      return 'study.err_done'.tr();
    }
    return null;
  }

  bool get _isValid => _titleCtrl.text.trim().isNotEmpty && _goalError == null;

  void _save()
  {
    Navigator.of(context).pop(TopicDraft(
      parentId: widget.topic?.parentId ?? widget.parentId,
      title: _titleCtrl.text,
      description: _descriptionCtrl.text,
      unit: _unit,
      target: _target!,
      done: _done!,
    ));
  }

  Widget _numberField(TextEditingController aCtrl, String aLabel, Key aKey)
  {
    return SizedBox(
      width: 150,
      child: TextField(
        key: aKey,
        controller: aCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(8)],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: aLabel, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final hasChildren = widget.topic?.hasChildren ?? false;
    final error = _goalError;

    return AlertDialog(
      scrollable: true,
      title: Text(widget.topic == null ? 'study.new_topic'.tr() : 'study.edit_topic'.tr()),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('topic.title'),
              controller: _titleCtrl,
              autofocus: widget.topic == null,
              inputFormatters: [LengthLimitingTextInputFormatter(maxTopicTitleLen)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'study.topic_title'.tr(), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionCtrl,
              minLines: 1,
              maxLines: 4,
              inputFormatters: [LengthLimitingTextInputFormatter(maxTopicDescriptionLen)],
              decoration: InputDecoration(labelText: 'study.description'.tr(), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Text('study.goal'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final unit in StudyUnit.values)
                  ChoiceChip(
                    key: ValueKey('topic.unit.${unit.name}'),
                    showCheckmark: false,
                    label: Text(unitLabel(unit)),
                    selected: _unit == unit,
                    onSelected: (_) => setState(() => _unit = unit),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (_unit != StudyUnit.percent) _numberField(_targetCtrl, 'study.target'.tr(), const ValueKey('topic.target')),
                _numberField(
                  _doneCtrl,
                  _unit == StudyUnit.percent ? 'study.done_percent'.tr() : 'study.done'.tr(),
                  const ValueKey('topic.done'),
                ),
              ],
            ),
            if (error != null && (_targetCtrl.text.isNotEmpty || _unit == StudyUnit.percent))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(error, style: TextStyle(fontSize: 12, color: palette.danger)),
              ),
            if (hasChildren)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('study.own_goal_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('topic.save'),
          onPressed: _isValid ? _save : null,
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

Future<double?> showProgressDialog(BuildContext aContext, StudyTopic aTopic)
{
  return showDialog<double>(context: aContext, builder: (_) => ProgressDialog(topic: aTopic));
}

class ProgressDialog extends StatefulWidget
{
  final StudyTopic topic;

  const ProgressDialog({super.key, required this.topic});

  @override
  State<ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<ProgressDialog>
{
  late final _ctrl = TextEditingController(text: _numberText(widget.topic.done));

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  double get _max => widget.topic.unit == StudyUnit.percent ? 100 : maxStudyGoal;

  double? get _value
  {
    final value = _parseNumber(_ctrl.text);
    return value == null || value < 0 || value > _max ? null : value;
  }

  void _add(double aStep)
  {
    final next = ((_parseNumber(_ctrl.text) ?? 0) + aStep).clamp(0, _max).toDouble();
    setState(() => _ctrl.text = _numberText(next));
  }

  @override
  Widget build(BuildContext aContext)
  {
    final topic = widget.topic;
    final isPercent = topic.unit == StudyUnit.percent;

    return AlertDialog(
      scrollable: true,
      title: Text(topic.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('progress.done'),
              controller: _ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(8)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: isPercent ? 'study.done_percent'.tr() : 'study.done'.tr(),
                suffixText: isPercent ? '%' : '/ ${studyNumber(aContext, topic.target)} ${'study.unit_short_${topic.unit.name}'.tr()}',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final step in progressSteps)
                  ActionChip(
                    key: ValueKey('progress.add.${step.toInt()}'),
                    label: Text('+${_numberText(step)}'),
                    onPressed: () => _add(step),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('progress.save'),
          onPressed: _value == null ? null : () => Navigator.of(aContext).pop(_value),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

class MoveTarget
{
  final StudyTopic? parent;

  const MoveTarget(this.parent);
}

Future<MoveTarget?> showMoveDialog(BuildContext aContext, StudyTree aTree, StudyTopic aTopic)
{
  final candidates = aTree.depthFirst().where((aCandidate) => aTree.canMoveUnder(aTopic.id, aCandidate)).toList();
  return showDialog<MoveTarget>(
    context: aContext,
    builder: (aDialogContext) => AlertDialog(
      title: Text('study.move_title'.tr(args: [aTopic.title])),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 420,
        height: dialogListHeight(aDialogContext, 420),
        child: ListView(
          children: [
            if (aTopic.parentId != null)
              ListTile(
                leading: const Icon(AppIcons.folderTree),
                title: Text('study.move_root'.tr()),
                onTap: () => Navigator.of(aDialogContext).pop(const MoveTarget(null)),
              ),
            for (final candidate in candidates)
              if (candidate.id != aTopic.parentId)
                ListTile(
                  contentPadding: EdgeInsets.only(left: 16.0 * candidate.depth, right: 16),
                  title: Text(candidate.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(aDialogContext).pop(MoveTarget(candidate)),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aDialogContext).pop(), child: Text('common.cancel'.tr())),
      ],
    ),
  );
}

class NoteResult
{
  final String? body;
  final DateTime noteTs;
  final bool isDelete;

  const NoteResult({this.body, required this.noteTs, this.isDelete = false});
}

Future<NoteResult?> showNoteEditor(BuildContext aContext, {StudyNote? aNote, required DateTime aInitialTs, String? aTopicTitle})
{
  return showDialog<NoteResult>(
    context: aContext,
    builder: (_) => NoteEditorDialog(note: aNote, initialTs: aInitialTs, topicTitle: aTopicTitle),
  );
}

class NoteEditorDialog extends StatefulWidget
{
  final StudyNote? note;
  final DateTime initialTs;
  final String? topicTitle;

  const NoteEditorDialog({super.key, this.note, required this.initialTs, this.topicTitle});

  @override
  State<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends State<NoteEditorDialog>
{
  late final _ctrl = TextEditingController(text: widget.note?.body ?? '');
  late DateTime _ts = widget.note?.noteTs ?? widget.initialTs;

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async
  {
    final picked = await showDatePicker(
      context: context,
      initialDate: _ts,
      firstDate: DateTime.now().subtract(const Duration(days: maxNoteDaysBack)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted)
    {
      setState(() => _ts = DateTime(picked.year, picked.month, picked.day, _ts.hour, _ts.minute));
    }
  }

  Future<void> _pickTime() async
  {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_ts));
    if (picked != null && mounted)
    {
      setState(() => _ts = DateTime(_ts.year, _ts.month, _ts.day, picked.hour, picked.minute));
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final topicTitle = widget.topicTitle;

    return AlertDialog(
      scrollable: true,
      title: Text(widget.note == null ? 'study.new_note'.tr() : 'study.edit_note'.tr()),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (topicTitle != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(topicTitle, style: TextStyle(color: palette.inkSecondary)),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ActionChip(
                  key: const ValueKey('note.date'),
                  avatar: const Icon(AppIcons.calendar, size: 16),
                  label: Text(DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(_ts)),
                  onPressed: _pickDate,
                ),
                ActionChip(
                  key: const ValueKey('note.time'),
                  avatar: const Icon(AppIcons.clock, size: 16),
                  label: Text(formatClock(aContext, _ts)),
                  onPressed: _pickTime,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('note.body'),
              controller: _ctrl,
              autofocus: true,
              minLines: 4,
              maxLines: 12,
              inputFormatters: [LengthLimitingTextInputFormatter(maxStudyNoteLen)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'study.note_text'.tr(),
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.note != null)
          TextButton(
            key: const ValueKey('note.delete'),
            style: TextButton.styleFrom(foregroundColor: palette.danger),
            onPressed: () => Navigator.of(aContext).pop(NoteResult(noteTs: _ts, isDelete: true)),
            child: Text('common.delete'.tr()),
          ),
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('note.save'),
          onPressed: _ctrl.text.trim().isEmpty ? null : () => Navigator.of(aContext).pop(NoteResult(body: _ctrl.text, noteTs: _ts)),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

Future<StudyTopic?> showTopicPicker(BuildContext aContext, StudyTree aTree)
{
  return showDialog<StudyTopic>(
    context: aContext,
    builder: (aDialogContext) => AlertDialog(
      title: Text('study.pick_topic'.tr()),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 420,
        height: dialogListHeight(aDialogContext, 420),
        child: ListView(
          children: [
            for (final topic in aTree.depthFirst())
              ListTile(
                key: ValueKey('topic.pick.${topic.id}'),
                contentPadding: EdgeInsets.only(left: 16.0 * topic.depth, right: 16),
                title: Text(topic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(progressLine(aDialogContext, topic.progress), style: const TextStyle(fontSize: 12)),
                onTap: () => Navigator.of(aDialogContext).pop(topic),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aDialogContext).pop(), child: Text('common.cancel'.tr())),
      ],
    ),
  );
}
