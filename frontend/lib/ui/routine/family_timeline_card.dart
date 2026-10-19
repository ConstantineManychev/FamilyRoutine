import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/range_days.dart';
import 'dash_card.dart';
import 'mark_sheet.dart';
import 'new_block_dialog.dart';
import 'routine_style.dart';
import 'status_sheet.dart';
import '../common/app_theme.dart';

const Duration _pollInterval = Duration(seconds: 30);
const double _rowHeight = 48;
const double _trackHeight = 24;
const double _blockGap = 2;
const double _blockRadius = 4;
const double _axisHeight = 20;
const double _multiAxisHeight = 34;
const double _minDayWidth = 120;
const double _minTickGap = 40;
const List<int> _hourSteps = [1, 2, 3, 6, 12, 24];

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
  DateTime _lastDay = _dayStart(DateTime.now());
  int _days = 1;
  TimelineDto? _data;
  Object? _error;
  Timer? _timer;
  int _requestId = 0;
  bool _isFollowingToday = true;

  DateTime get _from => rangeFirstDay(_lastDay, _days);

  DateTime get _to => DateTime(_lastDay.year, _lastDay.month, _lastDay.day + 1);

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
    _lastDay = _dayStart(DateTime.now());
    _load();
  }

  Future<void> _load() async
  {
    final requestId = ++_requestId;
    try
    {
      final data = await ref.read(apiProv).getTimeline(aFamilyId: widget.familyId, aFrom: _from, aTo: _to);
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

  void _setRange(DateTime aLastDay, int aDays)
  {
    setState(()
    {
      _lastDay = _dayStart(aLastDay);
      _days = aDays;
      _isFollowingToday = _lastDay == _dayStart(DateTime.now());
      _data = null;
    });
    _load();
  }

  Future<void> _create(TimelineMemberDto aMember, DateTime aTs) async
  {
    final isCreated = await openNewBlock(
      context,
      ref,
      aStart: aTs,
      aPersonId: aMember.isMe ? null : aMember.userId,
      aPersonName: aMember.fullName,
    );
    if (isCreated)
    {
      await _load();
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(routineRevisionProv, (_, __) => _load());
    final data = _data;
    final title = widget.title ?? data?.familyName ?? 'routine.my_day'.tr();

    return DashCard(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.calendarClock, size: 20, color: context.palette.inkSecondary),
          const SizedBox(width: 8),
          Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      menu: widget.menu,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RangeDaysBar(
            keyPrefix: 'timeline.range',
            lastDay: _lastDay,
            days: _days,
            maxDay: _dayStart(DateTime.now()).add(const Duration(days: 1)),
            onShift: (aDay) => _setRange(aDay, _days),
            onDays: (aDays) => _setRange(_lastDay, aDays),
          ),
          const SizedBox(height: 8),
          _buildBody(aContext, data),
        ],
      ),
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
          key: ValueKey('grid.${_from.toIso8601String()}.$_days'),
          from: _from,
          to: _to,
          members: aData.members,
          onOpenMark: (aMark) => openMarkSheet(context, aMark.id),
          onCreate: _create,
        ),
        const SizedBox(height: 12),
        if (!hasMarks)
          Text('routine.empty'.tr(), style: TextStyle(color: context.palette.inkMuted))
        else
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: RoutineStatus.values
                .where(usedStatuses.contains)
                .map((aStatus) => _LegendItem(status: aStatus))
                .toList(),
          ),
        const SizedBox(height: 6),
        Text('routine.tap_to_create'.tr(), style: TextStyle(fontSize: 12, color: context.palette.inkMuted)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(errorText(_error!), style: TextStyle(fontSize: 12, color: context.palette.danger)),
          ),
      ],
    );
  }
}

class _TimelineGrid extends StatefulWidget
{
  final DateTime from;
  final DateTime to;
  final List<TimelineMemberDto> members;
  final ValueChanged<StatusMarkDto> onOpenMark;
  final void Function(TimelineMemberDto aMember, DateTime aTs) onCreate;

  const _TimelineGrid({
    super.key,
    required this.from,
    required this.to,
    required this.members,
    required this.onOpenMark,
    required this.onCreate,
  });

  @override
  State<_TimelineGrid> createState() => _TimelineGridState();
}

class _TimelineGridState extends State<_TimelineGrid>
{
  final _scroll = ScrollController();
  bool _isPositioned = false;

  @override
  void dispose()
  {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToNow(double aX, double aViewport)
  {
    if (_isPositioned)
    {
      return;
    }
    _isPositioned = true;
    WidgetsBinding.instance.addPostFrameCallback((_)
    {
      if (mounted && _scroll.hasClients)
      {
        _scroll.jumpTo((aX - aViewport * 0.75).clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    return LayoutBuilder(
      builder: (aContext, aConstraints)
      {
        final width = aConstraints.maxWidth;
        final nameWidth = math.min(180.0, math.max(96.0, width * 0.24));
        final viewport = math.max(120.0, width - nameWidth - 12);
        final days = math.max(1, (widget.to.difference(widget.from).inHours / 24).round());
        final trackWidth = rangeContentWidth(viewport, days, _minDayWidth);
        final from = widget.from;
        final to = widget.to;
        final total = to.difference(from).inSeconds.toDouble();
        final now = DateTime.now();
        final isNowVisible = !now.isBefore(from) && now.isBefore(to);
        final isMultiDay = days > 1;
        final axisHeight = isMultiDay ? _multiAxisHeight : _axisHeight;
        final hours = math.max(1, to.difference(from).inMinutes / 60);
        final hourStep = _hourSteps.firstWhere((aStep) => aStep * trackWidth / hours >= _minTickGap, orElse: () => 24);

        double xOf(DateTime aTs)
        {
          final seconds = aTs.difference(from).inSeconds.clamp(0, total.toInt());
          return trackWidth * seconds / total;
        }

        DateTime tsOf(double aX) => from.add(Duration(seconds: (total * (aX / trackWidth).clamp(0.0, 1.0)).round()));

        final ticks = <DateTime>[];
        for (var tick = from; !tick.isAfter(to); tick = DateTime(tick.year, tick.month, tick.day, tick.hour + 1))
        {
          if (tick.hour % hourStep == 0)
          {
            ticks.add(tick);
          }
        }
        if (trackWidth > viewport && isNowVisible)
        {
          _scrollToNow(xOf(now), viewport);
        }
        final gridHeight = axisHeight + widget.members.length * _rowHeight;
        final locale = aContext.locale.toLanguageTag();

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
                    SizedBox(height: axisHeight),
                    for (final member in widget.members)
                      SizedBox(
                        height: _rowHeight,
                        child: _MemberLabel(
                          member: member,
                          isNowVisible: isNowVisible,
                          now: now,
                          onSetStatus: member.canEdit
                              ? () => showStatusSheet(
                                    aContext,
                                    aPersonId: member.isMe ? null : member.userId,
                                    aPersonName: member.fullName,
                                  )
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('timeline.scroll'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: trackWidth,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final tick in ticks) ...[
                          Positioned(
                            left: xOf(tick),
                            top: axisHeight,
                            bottom: 0,
                            child: Container(
                              width: tick.hour == 0 && isMultiDay ? 2 : 1,
                              color: tick.hour == 0 && isMultiDay ? aContext.palette.baseline : aContext.palette.grid,
                            ),
                          ),
                          if (hourStep < 24)
                            Positioned(
                              left: (xOf(tick) - 20).clamp(-4.0, trackWidth - 36),
                              width: 40,
                              top: isMultiDay ? 16 : 0,
                              child: Text(
                                '${tick.hour.toString().padLeft(2, '0')}:00',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11, color: aContext.palette.inkMuted),
                              ),
                            ),
                          if (isMultiDay && tick.hour == 0)
                            Positioned(
                              left: (xOf(tick) + 4).clamp(0.0, trackWidth - 80),
                              width: 80,
                              top: 0,
                              child: Text(
                                DateFormat.MMMEd(locale).format(tick),
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: aContext.palette.inkSecondary),
                              ),
                            ),
                        ],
                        for (var index = 0; index < widget.members.length; index++)
                          Positioned(
                            left: 0,
                            width: trackWidth,
                            top: axisHeight + index * _rowHeight + (_rowHeight - _trackHeight) / 2,
                            height: _trackHeight,
                            child: _MemberTrack(
                              member: widget.members[index],
                              from: from,
                              to: to,
                              now: now,
                              xOf: xOf,
                              onOpenMark: widget.onOpenMark,
                              onCreate: widget.members[index].canEdit
                                  ? (aX) => widget.onCreate(widget.members[index], tsOf(aX))
                                  : null,
                            ),
                          ),
                        if (isNowVisible)
                          Positioned(
                            left: xOf(now) - 1,
                            top: axisHeight - 4,
                            bottom: 0,
                            child: IgnorePointer(
                              child: Container(width: 2, color: aContext.palette.inkPrimary),
                            ),
                          ),
                      ],
                    ),
                  ),
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
  final VoidCallback? onSetStatus;

  const _MemberLabel({required this.member, required this.isNowVisible, required this.now, this.onSetStatus});

  @override
  Widget build(BuildContext aContext)
  {
    final current = isNowVisible ? member.markAt(now) : null;
    final name = member.isMe ? '${member.fName} (${'routine.you'.tr()})' : member.fullName;
    final setStatus = onSetStatus;

    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: member.isMe ? FontWeight.bold : FontWeight.w600, color: aContext.palette.inkPrimary),
              ),
            ),
            if (setStatus != null && !member.isMe) ...[
              const SizedBox(width: 4),
              Icon(AppIcons.pencil, size: 12, color: aContext.palette.inkMuted),
            ],
          ],
        ),
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Icon(current.status.icon, size: 12, color: current.status.colorOf(aContext)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    current.status.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: aContext.palette.inkSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (setStatus == null)
    {
      return label;
    }
    return InkWell(
      key: ValueKey('timeline.status.${member.userId}'),
      borderRadius: BorderRadius.circular(6),
      onTap: setStatus,
      child: Tooltip(message: 'routine.set_status_for'.tr(args: [member.fullName]), child: label),
    );
  }
}

class _MemberTrack extends StatelessWidget
{
  final TimelineMemberDto member;
  final DateTime from;
  final DateTime to;
  final DateTime now;
  final double Function(DateTime) xOf;
  final ValueChanged<StatusMarkDto> onOpenMark;
  final ValueChanged<double>? onCreate;

  const _MemberTrack({
    required this.member,
    required this.from,
    required this.to,
    required this.now,
    required this.xOf,
    required this.onOpenMark,
    this.onCreate,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final blocks = <Widget>[];
    for (final mark in member.marks)
    {
      final openEnd = now.isBefore(to) ? now : to;
      final end = mark.endTs ?? openEnd;
      if (!end.isAfter(from) || !end.isAfter(mark.startTs))
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
          isMine: member.canEdit,
          onTap: () => onOpenMark(mark),
        ),
      ));
    }
    final create = onCreate;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: aContext.palette.surfaceMuted,
        borderRadius: BorderRadius.circular(_blockRadius),
      ),
      child: Stack(
        children: [
          if (create != null)
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.cell,
                child: GestureDetector(
                  key: ValueKey('timeline.track.${member.userId}'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (aDetails) => create(aDetails.localPosition.dx),
                ),
              ),
            ),
          ...blocks,
        ],
      ),
    );
  }
}

class _MarkBlock extends StatelessWidget
{
  final StatusMarkDto mark;
  final String memberName;
  final double width;
  final Duration duration;
  final bool isMine;
  final VoidCallback onTap;

  const _MarkBlock({
    required this.mark,
    required this.memberName,
    required this.width,
    required this.duration,
    required this.isMine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final color = mark.status.colorOf(aContext);
    final iconColor = color.computeLuminance() > 0.3 ? aContext.palette.inkPrimary : Colors.white;
    final lines = [
      '$memberName — ${mark.status.label}',
      '${formatSpan(aContext, mark)} · ${formatDuration(duration)}',
      if (mark.note != null) mark.note!,
      isMine ? 'routine.tap_to_edit'.tr() : 'routine.tap_to_open'.tr(),
    ];

    final block = Container(
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(_blockRadius)),
      alignment: Alignment.center,
      child: width >= 20 ? Icon(mark.status.icon, size: 14, color: iconColor) : null,
    );

    return Semantics(
      label: lines.join('. '),
      button: true,
      child: Tooltip(
        message: lines.join('\n'),
        triggerMode: TooltipTriggerMode.longPress,
        waitDuration: const Duration(milliseconds: 150),
        child: MouseRegion(
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
          decoration: BoxDecoration(color: status.colorOf(aContext), borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Icon(status.icon, size: 14, color: aContext.palette.inkSecondary),
        const SizedBox(width: 4),
        Text(status.label, style: TextStyle(fontSize: 12, color: aContext.palette.inkSecondary)),
      ],
    );
  }
}
