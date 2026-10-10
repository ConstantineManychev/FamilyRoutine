import 'dart:async';
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
import 'dash_card.dart';
import 'routine_style.dart';

const Duration _pollInterval = Duration(seconds: 30);
const double _rowHeight = 48;
const double _trackHeight = 24;
const double _blockGap = 2;
const double _blockRadius = 4;
const double _axisHeight = 20;

DateTime _dayStart(DateTime aTs) => DateTime(aTs.year, aTs.month, aTs.day);

class FamilyTimelineCard extends ConsumerStatefulWidget
{
  final String? familyId;
  final String? title;
  final Widget? menu;

  const FamilyTimelineCard({super.key, this.familyId, this.title, this.menu});

  @override
  ConsumerState<FamilyTimelineCard> createState() => _FamilyTimelineCardState();
}

class _FamilyTimelineCardState extends ConsumerState<FamilyTimelineCard>
{
  DateTime _day = _dayStart(DateTime.now());
  TimelineDto? _data;
  Object? _error;
  Timer? _timer;
  int _requestId = 0;
  bool _isFollowingToday = true;

  bool get _isToday => _day == _dayStart(DateTime.now());

  @override
  void initState()
  {
    super.initState();
    _load();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  @override
  void didUpdateWidget(covariant FamilyTimelineCard aOldWidget)
  {
    super.didUpdateWidget(aOldWidget);
    if (aOldWidget.familyId != widget.familyId)
    {
      _load();
    }
  }

  @override
  void dispose()
  {
    _timer?.cancel();
    super.dispose();
  }

  void _poll()
  {
    if (!mounted || !_isFollowingToday)
    {
      return;
    }
    _day = _dayStart(DateTime.now());
    _load();
  }

  Future<void> _load() async
  {
    final requestId = ++_requestId;
    try
    {
      final data = await ref.read(apiProv).getTimeline(
            aFamilyId: widget.familyId,
            aFrom: _day,
            aTo: _day.add(const Duration(days: 1)),
          );
      if (mounted && requestId == _requestId)
      {
        setState(()
        {
          _data = data;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted && requestId == _requestId)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _shiftDay(int aDays)
  {
    setState(()
    {
      _day = _dayStart(_day.add(Duration(days: aDays, hours: 12)));
      _isFollowingToday = _isToday;
      _data = null;
    });
    _load();
  }

  void _goToday()
  {
    setState(()
    {
      _day = _dayStart(DateTime.now());
      _isFollowingToday = true;
      _data = null;
    });
    _load();
  }

  Future<void> _editMark(StatusMarkDto aMark) async
  {
    final result = await showDialog<_MarkEdit>(context: context, builder: (_) => _MarkEditDialog(mark: aMark));
    if (result == null || !mounted)
    {
      return;
    }

    try
    {
      final api = ref.read(apiProv);
      if (result.isDelete)
      {
        await api.deleteMark(aMark.id);
      }
      else
      {
        await api.updateMark(aMark.id, result.status, result.note);
      }
      ref.read(routineRevisionProv.notifier).state++;
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  String _dayLabel(BuildContext aContext)
  {
    final today = _dayStart(DateTime.now());
    final diff = _day.difference(today).inHours.round() ~/ 24;
    final date = DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(_day);
    return switch (diff)
    {
      0 => '${'routine.today'.tr()}, $date',
      -1 => '${'routine.yesterday'.tr()}, $date',
      1 => '${'routine.tomorrow'.tr()}, $date',
      _ => date,
    };
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(routineRevisionProv, (_, __) => _load());
    final data = _data;
    final title = widget.title ?? data?.familyName ?? 'routine.my_day'.tr();
    final canGoForward = _day.isBefore(_dayStart(DateTime.now()).add(const Duration(days: 1)));

    return DashCard(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(AppIcons.calendarClock, size: 20, color: inkSecondary),
          const SizedBox(width: 8),
          Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'routine.prev_day'.tr(),
              icon: const Icon(AppIcons.chevronLeft, size: 18),
              onPressed: () => _shiftDay(-1),
            ),
            Text(_dayLabel(aContext), style: const TextStyle(fontWeight: FontWeight.w600, color: inkSecondary)),
            IconButton(
              tooltip: 'routine.next_day'.tr(),
              icon: const Icon(AppIcons.chevronRight, size: 18),
              onPressed: canGoForward ? () => _shiftDay(1) : null,
            ),
            if (!_isToday)
              TextButton(onPressed: _goToday, child: Text('routine.today'.tr())),
          ],
        ),
      ],
      menu: widget.menu,
      child: _buildBody(aContext, data),
    );
  }

  Widget _buildBody(BuildContext aContext, TimelineDto? aData)
  {
    if (aData == null)
    {
      return _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
    }

    final hasMarks = aData.members.any((aMember) => aMember.marks.isNotEmpty);
    final usedStatuses = {
      for (final member in aData.members)
        for (final mark in member.marks) mark.status,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TimelineGrid(
          day: _day,
          members: aData.members,
          onEditMark: _editMark,
        ),
        const SizedBox(height: 12),
        if (!hasMarks)
          Text('routine.empty'.tr(), style: const TextStyle(color: inkMuted))
        else
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: RoutineStatus.values
                .where(usedStatuses.contains)
                .map((aStatus) => _LegendItem(status: aStatus))
                .toList(),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(errorText(_error!), style: TextStyle(fontSize: 12, color: Colors.red.shade800)),
          ),
      ],
    );
  }
}

class _TimelineGrid extends StatelessWidget
{
  final DateTime day;
  final List<TimelineMemberDto> members;
  final ValueChanged<StatusMarkDto> onEditMark;

  const _TimelineGrid({required this.day, required this.members, required this.onEditMark});

  @override
  Widget build(BuildContext aContext)
  {
    return LayoutBuilder(
      builder: (aContext, aConstraints)
      {
        final width = aConstraints.maxWidth;
        final nameWidth = math.min(180.0, math.max(96.0, width * 0.24));
        final trackWidth = math.max(120.0, width - nameWidth - 12);
        final hourStep = trackWidth >= 720 ? 2 : (trackWidth >= 360 ? 3 : 6);
        final dayEnd = day.add(const Duration(days: 1));
        final dayLength = dayEnd.difference(day).inSeconds.toDouble();
        final now = DateTime.now();
        final isNowVisible = !now.isBefore(day) && now.isBefore(dayEnd);

        double xOf(DateTime aTs)
        {
          final seconds = aTs.difference(day).inSeconds.clamp(0, dayLength.toInt());
          return trackWidth * seconds / dayLength;
        }

        final hours = [for (var hour = 0; hour <= 24; hour += hourStep) hour];
        final gridHeight = _axisHeight + members.length * _rowHeight;

        return SizedBox(
          height: gridHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: nameWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: _axisHeight),
                    for (final member in members)
                      SizedBox(
                        height: _rowHeight,
                        child: _MemberLabel(member: member, isNowVisible: isNowVisible, now: now),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: trackWidth,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final hour in hours) ...[
                      Positioned(
                        left: trackWidth * hour / 24,
                        top: _axisHeight,
                        bottom: 0,
                        child: Container(width: 1, color: gridColor),
                      ),
                      Positioned(
                        left: (trackWidth * hour / 24 - 20).clamp(-4.0, trackWidth - 36),
                        width: 40,
                        top: 0,
                        child: Text(
                          '${hour.toString().padLeft(2, '0')}:00',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11, color: inkMuted),
                        ),
                      ),
                    ],
                    for (var index = 0; index < members.length; index++)
                      Positioned(
                        left: 0,
                        width: trackWidth,
                        top: _axisHeight + index * _rowHeight + (_rowHeight - _trackHeight) / 2,
                        height: _trackHeight,
                        child: _MemberTrack(
                          member: members[index],
                          day: day,
                          dayEnd: dayEnd,
                          now: now,
                          xOf: xOf,
                          onEditMark: onEditMark,
                        ),
                      ),
                    if (isNowVisible)
                      Positioned(
                        left: xOf(now) - 1,
                        top: _axisHeight - 4,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Container(width: 2, color: inkPrimary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MemberLabel extends StatelessWidget
{
  final TimelineMemberDto member;
  final bool isNowVisible;
  final DateTime now;

  const _MemberLabel({required this.member, required this.isNowVisible, required this.now});

  @override
  Widget build(BuildContext aContext)
  {
    final current = isNowVisible ? member.markAt(now) : null;
    final name = member.isMe ? '${member.fName} (${'routine.you'.tr()})' : member.fullName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: member.isMe ? FontWeight.bold : FontWeight.w600, color: inkPrimary),
        ),
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Icon(current.status.icon, size: 12, color: current.status.color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    current.status.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: inkSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MemberTrack extends StatelessWidget
{
  final TimelineMemberDto member;
  final DateTime day;
  final DateTime dayEnd;
  final DateTime now;
  final double Function(DateTime) xOf;
  final ValueChanged<StatusMarkDto> onEditMark;

  const _MemberTrack({
    required this.member,
    required this.day,
    required this.dayEnd,
    required this.now,
    required this.xOf,
    required this.onEditMark,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final blocks = <Widget>[];
    for (final mark in member.marks)
    {
      final openEnd = now.isBefore(dayEnd) ? now : dayEnd;
      final end = mark.endTs ?? openEnd;
      if (!end.isAfter(day) || !end.isAfter(mark.startTs))
      {
        continue;
      }
      final left = xOf(mark.startTs);
      final width = math.max(_blockGap, xOf(end) - left - _blockGap);
      blocks.add(Positioned(
        left: left,
        width: width,
        top: 0,
        bottom: 0,
        child: _MarkBlock(
          mark: mark,
          memberName: member.fullName,
          width: width,
          duration: end.difference(mark.startTs),
          onTap: member.isMe ? () => onEditMark(mark) : null,
        ),
      ));
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF4F4F1),
        borderRadius: BorderRadius.circular(_blockRadius),
      ),
      child: Stack(children: blocks),
    );
  }
}

class _MarkBlock extends StatelessWidget
{
  final StatusMarkDto mark;
  final String memberName;
  final double width;
  final Duration duration;
  final VoidCallback? onTap;

  const _MarkBlock({
    required this.mark,
    required this.memberName,
    required this.width,
    required this.duration,
    required this.onTap,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final color = mark.status.color;
    final iconColor = color.computeLuminance() > 0.3 ? inkPrimary : Colors.white;
    final lines = [
      '$memberName — ${mark.status.label}',
      '${formatSpan(aContext, mark)} · ${formatDuration(duration)}',
      if (mark.note != null) mark.note!,
      if (onTap != null) 'routine.tap_to_edit'.tr(),
    ];

    final block = Container(
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(_blockRadius)),
      alignment: Alignment.center,
      child: width >= 20 ? Icon(mark.status.icon, size: 14, color: iconColor) : null,
    );

    return Semantics(
      label: lines.join('. '),
      button: onTap != null,
      child: Tooltip(
        message: lines.join('\n'),
        triggerMode: onTap == null ? TooltipTriggerMode.tap : TooltipTriggerMode.longPress,
        waitDuration: const Duration(milliseconds: 150),
        child: onTap == null
            ? block
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(onTap: onTap, child: block),
              ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget
{
  final RoutineStatus status;

  const _LegendItem({required this.status});

  @override
  Widget build(BuildContext aContext)
  {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: status.color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Icon(status.icon, size: 14, color: inkSecondary),
        const SizedBox(width: 4),
        Text(status.label, style: const TextStyle(fontSize: 12, color: inkSecondary)),
      ],
    );
  }
}

class _MarkEdit
{
  final RoutineStatus status;
  final String? note;
  final bool isDelete;

  const _MarkEdit({required this.status, this.note, this.isDelete = false});
}

class _MarkEditDialog extends StatefulWidget
{
  final StatusMarkDto mark;

  const _MarkEditDialog({required this.mark});

  @override
  State<_MarkEditDialog> createState() => _MarkEditDialogState();
}

class _MarkEditDialogState extends State<_MarkEditDialog>
{
  late RoutineStatus _status = widget.mark.status;
  late final TextEditingController _noteCtrl = TextEditingController(text: widget.mark.note ?? '');

  @override
  void dispose()
  {
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('routine.edit_mark'.tr()),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatSpan(aContext, widget.mark), style: const TextStyle(color: inkSecondary)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: RoutineStatus.values
                  .map((aStatus) => ChoiceChip(
                        avatar: Icon(aStatus.icon, size: 16, color: aStatus.color),
                        label: Text(aStatus.label),
                        selected: aStatus == _status,
                        onSelected: (_) => setState(() => _status = aStatus),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _noteCtrl,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              decoration: InputDecoration(labelText: 'routine.note'.tr(), border: const OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: Colors.red.shade800),
          onPressed: () => Navigator.of(aContext).pop(_MarkEdit(status: _status, isDelete: true)),
          icon: const Icon(AppIcons.trash2, size: 16),
          label: Text('common.delete'.tr()),
        ),
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: () => Navigator.of(aContext).pop(_MarkEdit(status: _status, note: _noteCtrl.text)),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}
