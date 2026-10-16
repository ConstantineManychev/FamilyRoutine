import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../training/training_revision.dart';
import 'planner_common.dart';

const Duration _clockTick = Duration(minutes: 1);

DateTime _mondayOf(DateTime aDate) => shiftDays(aDate, DateTime.monday - aDate.weekday);

Future<void> openNewPlanEvent(BuildContext aContext, WidgetRef aRef, DateTime aDate) async
{
  await aContext.push('/app/planner/events/new?date=${dateWire(aDate)}');
  notifyPlannerChanged(aRef);
}

mixin _AgendaLoader<T extends ConsumerStatefulWidget> on ConsumerState<T>
{
  List<Occurrence>? occurrences;
  Object? loadError;
  DateTime now = DateTime.now();
  Timer? _ticker;
  int _request = 0;

  DateTime get rangeFrom;

  DateTime get rangeTo;

  void startAgenda()
  {
    loadAgenda();
    _ticker = Timer.periodic(_clockTick, (_)
    {
      if (mounted)
      {
        setState(() => now = DateTime.now());
      }
    });
  }

  void stopAgenda() => _ticker?.cancel();

  Future<void> loadAgenda() async
  {
    final request = ++_request;
    try
    {
      final items = await ref.read(apiProv).getAgenda(rangeFrom, rangeTo);
      if (mounted && request == _request)
      {
        setState(()
        {
          occurrences = items;
          loadError = null;
          now = DateTime.now();
        });
      }
    }
    catch (aError)
    {
      if (mounted && request == _request)
      {
        setState(() => loadError = aError);
      }
    }
  }

  void listenAgendaChanges()
  {
    ref.listen<int>(plannerRevisionProv, (_, __) => loadAgenda());
    ref.listen<int>(trainingRevisionProv, (_, __) => loadAgenda());
  }
}

class PlannerScreen extends ConsumerStatefulWidget
{
  const PlannerScreen({super.key});

  @override
  ConsumerState<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends ConsumerState<PlannerScreen> with _AgendaLoader<PlannerScreen>
{
  DateTime _weekStart = _mondayOf(DateTime.now());

  @override
  DateTime get rangeFrom => _weekStart;

  @override
  DateTime get rangeTo => shiftDays(_weekStart, DateTime.daysPerWeek - 1);

  @override
  void initState()
  {
    super.initState();
    startAgenda();
  }

  @override
  void dispose()
  {
    stopAgenda();
    super.dispose();
  }

  void _showWeek(DateTime aAnyDay)
  {
    setState(()
    {
      _weekStart = _mondayOf(aAnyDay);
      occurrences = null;
    });
    loadAgenda();
  }

  DateTime get _newEventDate
  {
    final today = dayOnly(DateTime.now());
    return today.isBefore(rangeFrom) || today.isAfter(rangeTo) ? rangeFrom : today;
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    listenAgendaChanges();

    return ListPage(
      title: 'planner.title'.tr(),
      onAdd: () => openNewPlanEvent(aContext, ref, _newEventDate),
      addTooltip: 'planner.add'.tr(),
      actions: [
        IconButton(tooltip: 'planner.today'.tr(), icon: const Icon(AppIcons.calendar), onPressed: () => _showWeek(DateTime.now())),
      ],
      child: _buildBody(aContext),
    );
  }

  Widget _buildBody(BuildContext aContext)
  {
    final items = occurrences;
    if (items == null)
    {
      return loadError != null
          ? ErrorRetry(error: loadError!, onRetry: loadAgenda)
          : const Center(child: CircularProgressIndicator());
    }

    final localeTag = aContext.locale.toLanguageTag();
    final rangeLabel = '${DateFormat.MMMd(localeTag).format(rangeFrom)} – ${DateFormat.yMMMd(localeTag).format(rangeTo)}';
    final days = [for (var index = 0; index < DateTime.daysPerWeek; index++) shiftDays(rangeFrom, index)];

    return RefreshIndicator(
      onRefresh: loadAgenda,
      child: ListView(
        padding: tabPadding(aContext),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'planner.prev_week'.tr(),
                  icon: const Icon(AppIcons.chevronLeft),
                  onPressed: () => _showWeek(shiftDays(_weekStart, -DateTime.daysPerWeek)),
                ),
                Expanded(
                  child: Text(
                    rangeLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'planner.next_week'.tr(),
                  icon: const Icon(AppIcons.chevronRight),
                  onPressed: () => _showWeek(shiftDays(_weekStart, DateTime.daysPerWeek)),
                ),
              ],
            ),
          ),
          for (final day in days)
            _DaySection(
              date: day,
              occurrences: items.where((aItem) => DateUtils.isSameDay(aItem.date, day)).toList(),
              now: now,
              onAdd: (aDate) => openNewPlanEvent(aContext, ref, aDate),
            ),
        ],
      ),
    );
  }
}

class _DaySection extends StatelessWidget
{
  final DateTime date;
  final List<Occurrence> occurrences;
  final DateTime now;
  final ValueChanged<DateTime> onAdd;

  const _DaySection({required this.date, required this.occurrences, required this.now, required this.onAdd});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final isToday = DateUtils.isSameDay(date, now);
    final hasIssue = occurrences.any((aItem) => aItem.hasIssue);
    final dayLabel = DateFormat.MMMMEEEEd(aContext.locale.toLanguageTag()).format(date);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        shape: isToday
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: aContext.colors.primary, width: 1.5),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isToday ? '$dayLabel · ${'planner.today'.tr()}' : dayLabel,
                      style: TextStyle(fontWeight: FontWeight.w700, color: isToday ? aContext.colors.primary : palette.inkPrimary),
                    ),
                  ),
                  if (hasIssue) Icon(AppIcons.alertCircle, size: 18, color: palette.danger),
                  IconButton(
                    tooltip: 'planner.add'.tr(),
                    icon: const Icon(AppIcons.plus, size: 20),
                    onPressed: () => onAdd(date),
                  ),
                ],
              ),
              if (occurrences.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Text('planner.day_empty'.tr(), style: TextStyle(color: palette.inkMuted)),
                )
              else
                OccurrenceList(occurrences: occurrences, now: now),
            ],
          ),
        ),
      ),
    );
  }
}

class TodayPlanBlock extends ConsumerStatefulWidget
{
  const TodayPlanBlock({super.key});

  @override
  ConsumerState<TodayPlanBlock> createState() => _TodayPlanBlockState();
}

class _TodayPlanBlockState extends ConsumerState<TodayPlanBlock> with _AgendaLoader<TodayPlanBlock>
{
  DateTime _day = dayOnly(DateTime.now());

  @override
  DateTime get rangeFrom => _day;

  @override
  DateTime get rangeTo => _day;

  @override
  void initState()
  {
    super.initState();
    startAgenda();
  }

  @override
  void dispose()
  {
    stopAgenda();
    super.dispose();
  }

  Future<void> _openPlanner() async
  {
    await context.push('/app/planner');
    await loadAgenda();
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    listenAgendaChanges();
    if (!DateUtils.isSameDay(_day, now))
    {
      _day = dayOnly(now);
      Future.microtask(loadAgenda);
    }

    final items = occurrences;
    final Widget content;
    if (items == null)
    {
      content = loadError != null
          ? ErrorRetry(error: loadError!, onRetry: loadAgenda)
          : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else if (items.isEmpty)
    {
      content = BlockEmpty('planner.today_empty'.tr());
    }
    else
    {
      content = OccurrenceList(occurrences: items, now: now);
    }

    return BlockCard(
      title: 'planner.today_block'.tr(),
      onAdd: () => openNewPlanEvent(aContext, ref, _day),
      addTooltip: 'planner.add'.tr(),
      onExpand: _openPlanner,
      child: content,
    );
  }
}
