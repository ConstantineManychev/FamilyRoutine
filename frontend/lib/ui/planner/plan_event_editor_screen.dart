import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_tz.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../routine/routine_style.dart';
import 'plan_content_editor.dart';
import 'planner_common.dart';

const int _minDurationMin = 5;
const int _maxDurationMin = 24 * 60;
const int _defaultDurationMin = 60;
const int _defaultWindowMin = 4 * 60;
const int _maxRepeatEvery = 365;
const int _maxTitleLength = 100;
const int _maxNoteLength = 500;
const int _fullWeekMask = 0x7f;

class PlanEventEditorScreen extends ConsumerStatefulWidget
{
  final String? eventId;
  final DateTime? initialDate;
  final String? personId;

  const PlanEventEditorScreen({super.key, this.eventId, this.initialDate, this.personId});

  @override
  ConsumerState<PlanEventEditorScreen> createState() => _PlanEventEditorScreenState();
}

class _PlanEventEditorScreenState extends ConsumerState<PlanEventEditorScreen>
{
  final _titleCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _durationCtrl = TextEditingController(text: '$_defaultDurationMin');
  final _everyCtrl = TextEditingController(text: '1');

  RoutineStatus? _category;
  PlanTiming _timing = PlanTiming.fixed;
  late DateTime _startDate = dayOnly(widget.initialDate ?? DateTime.now());
  ClockTime _startTime = _nextHour();
  ClockTime _windowEnd = _nextHour().plusMinutes(_defaultWindowMin);
  PlanRepeat _repeat = PlanRepeat.once;
  int _weekdayMask = 0;
  DateTime? _untilDate;
  String _tz = deviceTimeZone();
  List<String> _timeZones = const [];
  List<ProgramListItem> _programs = const [];
  late String? _ownerId = widget.personId;
  String? _programId;
  List<ProgramDay> _programDays = const [];
  String? _dayId;
  bool _isScheduleFromProgram = false;
  PlanContentDraft _content = PlanContentDraft();

  Object? _loadError;
  bool _isLoading = true;
  bool _isSaving = false;

  bool get _isEdit => widget.eventId != null;

  static ClockTime _nextHour() => ClockTime(DateTime.now().hour, 0).plusMinutes(60);

  @override
  void initState()
  {
    super.initState();
    _initData();
  }

  @override
  void dispose()
  {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _durationCtrl.dispose();
    _everyCtrl.dispose();
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
      final zonesFuture = api.getTimeZones();
      final event = _isEdit ? await api.getPlanEvent(widget.eventId!) : null;
      final ownerId = event?.ownerId;
      if (event != null)
      {
        _ownerId = ownerId == null || ownerId == ref.read(sessionUserIdProv) ? null : ownerId;
      }
      _programs = await api.getPrograms(aPersonId: _ownerId);
      _timeZones = await zonesFuture;
      if (event != null)
      {
        _apply(event);
      }
      if (_programId != null)
      {
        _programDays = (await api.getProgram(_programId!)).days;
      }
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

  void _apply(PlanEvent aEvent)
  {
    _titleCtrl.text = aEvent.title;
    _noteCtrl.text = aEvent.note ?? '';
    _durationCtrl.text = '${aEvent.durationMin}';
    _everyCtrl.text = '${aEvent.repeatEvery}';
    _category = aEvent.category;
    _timing = aEvent.timing;
    _startDate = aEvent.startDate;
    _startTime = aEvent.startTime;
    _windowEnd = aEvent.startTime.plusMinutes(aEvent.windowMin ?? aEvent.durationMin);
    _repeat = aEvent.repeat;
    _weekdayMask = aEvent.weekdayMask;
    _untilDate = aEvent.untilDate;
    _tz = aEvent.tz;
    _programId = aEvent.programId;
    _dayId = aEvent.dayId;
    _content = PlanContentDraft.of(aEvent.content);
  }

  int get _windowMin
  {
    final span = (_windowEnd.totalMinutes - _startTime.totalMinutes) % _maxDurationMin;
    return span == 0 ? _maxDurationMin : span;
  }

  int get _effectiveWeekdayMask => _weekdayMask == 0 ? _weekdayBit(_startDate) : _weekdayMask & _fullWeekMask;

  int _weekdayBit(DateTime aDate) => 1 << (aDate.weekday - DateTime.monday);

  Future<void> _pickDate() async
  {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null)
    {
      setState(()
      {
        _startDate = picked;
        if (_untilDate != null && _untilDate!.isBefore(picked))
        {
          _untilDate = picked;
        }
      });
    }
  }

  Future<void> _pickUntil() async
  {
    final picked = await showDatePicker(
      context: context,
      initialDate: _untilDate ?? shiftDays(_startDate, 30),
      firstDate: _startDate,
      lastDate: DateTime(2100),
    );
    if (picked != null)
    {
      setState(() => _untilDate = picked);
    }
  }

  Future<ClockTime?> _pickTime(ClockTime aInitial) async
  {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: aInitial.hour, minute: aInitial.minute));
    return picked == null ? null : ClockTime(picked.hour, picked.minute);
  }

  Future<void> _pickStart() async
  {
    final picked = await _pickTime(_startTime);
    if (picked != null)
    {
      setState(()
      {
        final window = _windowMin;
        _startTime = picked;
        _windowEnd = picked.plusMinutes(window);
      });
    }
  }

  Future<void> _pickWindowEnd() async
  {
    final picked = await _pickTime(_windowEnd);
    if (picked != null)
    {
      setState(() => _windowEnd = picked);
    }
  }

  Future<void> _pickTimeZone() async
  {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _TimeZoneDialog(zones: _timeZones, current: _tz),
    );
    if (picked != null)
    {
      setState(() => _tz = picked);
    }
  }

  Future<void> _selectProgram(String? aProgramId) async
  {
    setState(()
    {
      _programId = aProgramId;
      _dayId = null;
      _programDays = const [];
      _isScheduleFromProgram = false;
    });
    if (aProgramId == null)
    {
      return;
    }

    final program = _programs.where((aItem) => aItem.id == aProgramId).firstOrNull;
    if (program != null && _titleCtrl.text.trim().isEmpty)
    {
      _titleCtrl.text = program.name;
    }
    setState(() => _category ??= RoutineStatus.gym);

    try
    {
      final program = await ref.read(apiProv).getProgram(aProgramId);
      if (mounted && _programId == aProgramId)
      {
        setState(()
        {
          _programDays = program.days;
          _isScheduleFromProgram = _applyProgramSchedule(program);
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

  bool _applyProgramSchedule(TrainingProgram aProgram)
  {
    final days = aProgram.days;
    if (days.isEmpty)
    {
      return false;
    }
    switch (aProgram.mode)
    {
      case ScheduleMode.weekdays:
        final mask = days.fold<int>(
          0,
          (aMask, aDay) => aDay.weekdays.fold<int>(aMask, (aBits, aWeekday) => aBits | (1 << (aWeekday - DateTime.monday))),
        );
        if (mask == 0)
        {
          return false;
        }
        _repeat = PlanRepeat.weekly;
        _weekdayMask = mask & _fullWeekMask;
        _everyCtrl.text = '1';
      case ScheduleMode.intervals:
        final gap = days.map((aDay) => aDay.restDaysAfter).reduce(math.min) + 1;
        _repeat = PlanRepeat.daily;
        _everyCtrl.text = '${gap.clamp(1, _maxRepeatEvery)}';
      case ScheduleMode.queue:
        return false;
    }
    _dayId = null;
    return true;
  }

  void _toggleWeekday(int aBit)
  {
    setState(()
    {
      final mask = _effectiveWeekdayMask;
      final next = mask ^ aBit;
      _weekdayMask = next == 0 ? mask : next;
    });
  }

  String? _validate(int? aDuration, int? aEvery)
  {
    if (_titleCtrl.text.trim().isEmpty)
    {
      return 'planner.err_title';
    }
    if (aDuration == null || aDuration < _minDurationMin || aDuration > _maxDurationMin)
    {
      return 'planner.err_duration';
    }
    if (_timing == PlanTiming.window && _windowMin < aDuration)
    {
      return 'planner.err_window';
    }
    if (aEvery == null || aEvery < 1 || aEvery > _maxRepeatEvery)
    {
      return 'errors.VALIDATION';
    }
    return null;
  }

  Future<void> _save() async
  {
    FocusScope.of(context).unfocus();
    final duration = int.tryParse(_durationCtrl.text.trim());
    final every = _repeat == PlanRepeat.once ? 1 : int.tryParse(_everyCtrl.text.trim());
    final errorKey = _validate(duration, every);
    if (errorKey != null)
    {
      showInfoSnack(context, errorKey.tr());
      return;
    }

    final payload = PlanEvent.payload(
      aTitle: _titleCtrl.text.trim(),
      aNote: _noteCtrl.text,
      aCategory: _category,
      aTiming: _timing,
      aStartDate: _startDate,
      aStartTime: _startTime,
      aWindowMin: _windowMin,
      aDurationMin: duration!,
      aTz: _tz,
      aRepeat: _repeat,
      aRepeatEvery: every!,
      aWeekdayMask: _repeat == PlanRepeat.weekly ? _effectiveWeekdayMask : 0,
      aUntilDate: _repeat == PlanRepeat.once ? null : _untilDate,
      aProgramId: _programId,
      aDayId: _programId == null ? null : _dayId,
      aContent: _content.toJson(_category),
    );

    setState(() => _isSaving = true);
    try
    {
      await ref.read(apiProv).savePlanEvent(widget.eventId, {
        ...payload,
        if (!_isEdit && _ownerId != null) 'person_id': _ownerId,
      });
      notifyPlannerChanged(ref);
      if (mounted)
      {
        finishPage(context, '/app/planner');
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

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(context, aTitle: 'planner.delete'.tr(), aMessage: 'planner.delete_confirm'.tr());
    if (!isConfirmed || !mounted)
    {
      return;
    }
    setState(() => _isSaving = true);
    try
    {
      await ref.read(apiProv).deletePlanEvent(widget.eventId!);
      notifyPlannerChanged(ref);
      if (mounted)
      {
        finishPage(context, '/app/planner');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
        showErrorSnack(context, aError);
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

    final localeTag = aContext.locale.toLanguageTag();
    const gap = SizedBox(height: 16);
    const fieldWidth = 160.0;
    final people = ref.watch(peopleProv).valueOrNull ?? const <PersonRef>[];
    final owner = people.where((aPerson) => aPerson.id == _ownerId).firstOrNull;
    final title = _isEdit ? 'planner.event'.tr() : 'planner.new_event'.tr();

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: owner == null ? title : '$title · ${owner.fullName}',
          actions: [
            if (_isEdit)
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _delete,
                icon: Icon(AppIcons.trash, color: aContext.palette.danger, size: 18),
                label: Text('common.delete'.tr()),
              ),
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(AppIcons.save, size: 18),
              label: Text('common.save'.tr()),
            ),
          ],
        ),
        if (_isEdit && _repeat != PlanRepeat.once) ...[
          const SizedBox(height: 12),
          Text('planner.series_hint'.tr(), style: TextStyle(color: aContext.palette.inkSecondary)),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _titleCtrl,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(_maxTitleLength)],
          decoration: _decoration('planner.title_field'),
        ),
        gap,
        DropdownButtonFormField<RoutineStatus?>(
          key: ValueKey('category:$_category'),
          initialValue: _category,
          isExpanded: true,
          decoration: _decoration('planner.category'),
          items: [
            DropdownMenuItem(value: null, child: Text('planner.category_none'.tr())),
            for (final status in RoutineStatus.values)
              DropdownMenuItem(
                value: status,
                child: Row(
                  children: [
                    Icon(status.icon, size: 18, color: status.colorOf(aContext)),
                    const SizedBox(width: 8),
                    Flexible(child: Text(status.label, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
          ],
          onChanged: (aValue) => setState(() => _category = aValue),
        ),
        if (hasPlanContent(_category)) ...[
          gap,
          Container(
            key: const ValueKey('editor.content'),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            decoration: BoxDecoration(
              border: Border.all(color: aContext.palette.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlanContentEditor(
                  key: ValueKey('content:$_category'),
                  category: _category,
                  draft: _content,
                  personId: _ownerId,
                  isEnabled: !_isSaving,
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'planner.content_hint'.tr(),
                    style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
                  ),
                ),
              ],
            ),
          ),
        ],
        gap,
        SegmentedButton<PlanTiming>(
          showSelectedIcon: false,
          segments: [
            for (final timing in PlanTiming.values)
              ButtonSegment(
                value: timing,
                label: Text('planner.timing_${timing.name}'.tr(), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          selected: {_timing},
          onSelectionChanged: (aValue) => setState(() => _timing = aValue.first),
        ),
        const SizedBox(height: 8),
        Text(
          'planner.timing_hint_${_timing.name}'.tr(),
          style: TextStyle(fontSize: 13, color: aContext.palette.inkSecondary),
        ),
        gap,
        _PickerField(
          label: 'planner.date'.tr(),
          value: DateFormat.yMMMEd(localeTag).format(_startDate),
          icon: AppIcons.calendar,
          onTap: _pickDate,
        ),
        gap,
        Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            SizedBox(
              width: fieldWidth,
              child: _PickerField(
                label: _timing == PlanTiming.fixed ? 'planner.start'.tr() : 'planner.window_from'.tr(),
                value: _startTime.label,
                icon: AppIcons.clock,
                onTap: _pickStart,
              ),
            ),
            if (_timing == PlanTiming.window)
              SizedBox(
                width: fieldWidth,
                child: _PickerField(label: 'planner.window_to'.tr(), value: _windowEnd.label, icon: AppIcons.clock, onTap: _pickWindowEnd),
              ),
            SizedBox(
              width: fieldWidth,
              child: TextField(
                controller: _durationCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                decoration: _decoration('planner.duration'),
              ),
            ),
          ],
        ),
        gap,
        DropdownButtonFormField<PlanRepeat>(
          key: ValueKey('repeat:$_repeat'),
          initialValue: _repeat,
          isExpanded: true,
          decoration: _decoration('planner.repeat'),
          items: [
            for (final repeat in PlanRepeat.values)
              DropdownMenuItem(value: repeat, child: Text('planner.repeat_${repeat.name}'.tr())),
          ],
          onChanged: (aValue) => setState(() => _repeat = aValue ?? PlanRepeat.once),
        ),
        if (_repeat != PlanRepeat.once) ...[
          gap,
          Row(
            children: [
              SizedBox(
                width: fieldWidth,
                child: TextField(
                  controller: _everyCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                  decoration: _decoration('planner.repeat_every'),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(child: Text('planner.unit_${_repeat.name}'.tr())),
            ],
          ),
          if (_repeat == PlanRepeat.weekly) ...[
            gap,
            Text('planner.weekdays'.tr(), style: TextStyle(color: aContext.palette.inkSecondary)),
            const SizedBox(height: 8),
            _WeekdayPicker(mask: _effectiveWeekdayMask, localeTag: localeTag, onToggle: _toggleWeekday),
          ],
          gap,
          _PickerField(
            label: 'planner.until'.tr(),
            value: _untilDate == null ? 'planner.until_none'.tr() : DateFormat.yMMMd(localeTag).format(_untilDate!),
            icon: AppIcons.calendarClock,
            onTap: _pickUntil,
            onClear: _untilDate == null ? null : () => setState(() => _untilDate = null),
            clearTooltip: 'planner.until_none'.tr(),
          ),
        ],
        gap,
        _PickerField(
          label: 'planner.tz'.tr(),
          value: _tz.replaceAll('_', ' '),
          icon: AppIcons.globe,
          onTap: _pickTimeZone,
          helper: 'planner.tz_hint'.tr(),
        ),
        gap,
        DropdownButtonFormField<String?>(
          initialValue: _programs.any((aItem) => aItem.id == _programId) ? _programId : null,
          isExpanded: true,
          decoration: _decoration('planner.training'),
          items: [
            DropdownMenuItem(value: null, child: Text('planner.training_none'.tr())),
            for (final program in _programs)
              DropdownMenuItem(value: program.id, child: Text(program.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: _isSaving ? null : _selectProgram,
        ),
        if (_programId != null) ...[
          gap,
          DropdownButtonFormField<String?>(
            key: ValueKey('days:$_programId:${_programDays.length}'),
            initialValue: _programDays.any((aDay) => aDay.id == _dayId) ? _dayId : null,
            isExpanded: true,
            decoration: _decoration('planner.training_day'),
            items: [
              DropdownMenuItem(value: null, child: Text('planner.training_next_day'.tr())),
              for (final day in _programDays.where((aDay) => aDay.id != null))
                DropdownMenuItem(value: day.id, child: Text(day.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (aValue) => setState(() => _dayId = aValue),
          ),
          if (_isScheduleFromProgram)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'planner.program_schedule'.tr(),
                key: const ValueKey('editor.program_schedule'),
                style: TextStyle(fontSize: 12, color: context.palette.inkMuted),
              ),
            ),
        ],
        gap,
        TextField(
          controller: _noteCtrl,
          minLines: 2,
          maxLines: 5,
          inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLength)],
          decoration: _decoration('planner.note'),
        ),
      ],
    );
  }
}

class _PickerField extends StatelessWidget
{
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final String? clearTooltip;
  final String? helper;

  const _PickerField({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.onClear,
    this.clearTooltip,
    this.helper,
  });

  @override
  Widget build(BuildContext aContext)
  {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon, size: 18),
          suffixIcon: onClear == null
              ? null
              : IconButton(tooltip: clearTooltip, icon: const Icon(AppIcons.x, size: 18), onPressed: onClear),
        ),
        child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _WeekdayPicker extends StatelessWidget
{
  final int mask;
  final String localeTag;
  final ValueChanged<int> onToggle;

  const _WeekdayPicker({required this.mask, required this.localeTag, required this.onToggle});

  @override
  Widget build(BuildContext aContext)
  {
    final monday = DateTime(2024, 1, 1);
    final format = DateFormat.E(localeTag);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var index = 0; index < DateTime.daysPerWeek; index++)
          FilterChip(
            label: Text(format.format(monday.add(Duration(days: index)))),
            selected: mask & (1 << index) != 0,
            showCheckmark: false,
            onSelected: (_) => onToggle(1 << index),
          ),
      ],
    );
  }
}

class _TimeZoneDialog extends StatefulWidget
{
  final List<String> zones;
  final String current;

  const _TimeZoneDialog({required this.zones, required this.current});

  @override
  State<_TimeZoneDialog> createState() => _TimeZoneDialogState();
}

class _TimeZoneDialogState extends State<_TimeZoneDialog>
{
  String _query = '';

  @override
  Widget build(BuildContext aContext)
  {
    final needle = _query.trim().toLowerCase().replaceAll(' ', '_');
    final device = deviceTimeZone();
    final matches = widget.zones.where((aZone) => needle.isEmpty || aZone.toLowerCase().contains(needle)).toList();
    if (needle.isEmpty && matches.remove(device))
    {
      matches.insert(0, device);
    }

    return AlertDialog(
      title: Text('planner.tz'.tr()),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'common.search'.tr(),
                prefixIcon: const Icon(AppIcons.search, size: 18),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (aValue) => setState(() => _query = aValue),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: dialogListHeight(aContext, 360),
              child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (_, aIndex)
                {
                  final zone = matches[aIndex];
                  return ListTile(
                    dense: true,
                    title: Text(zone.replaceAll('_', ' ')),
                    trailing: zone == widget.current ? const Icon(AppIcons.check, size: 18) : null,
                    onTap: () => Navigator.of(aContext).pop(zone),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
      ],
    );
  }
}
