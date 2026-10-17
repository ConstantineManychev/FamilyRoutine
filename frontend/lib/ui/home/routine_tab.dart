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
import '../common/person_switcher.dart';
import '../energy/energy_chart_block.dart';
import '../planner/planner_screen.dart';
import '../nutrition/nutrition_today_block.dart';
import '../routine/family_timeline_card.dart';
import '../stock/stock_today_block.dart';
import '../study/study_today_block.dart';
import '../training/next_workout_card.dart';
import '../training/person_training_card.dart';
import '../training/training_revision.dart';
import '../work/work_today_block.dart';

const int _recentProgramCount = 5;
const double _blockGap = 16;

class RoutineTab extends ConsumerStatefulWidget
{
  const RoutineTab({super.key});

  @override
  ConsumerState<RoutineTab> createState() => _RoutineTabState();
}

class _RoutineTabState extends ConsumerState<RoutineTab> with AutomaticKeepAliveClientMixin
{
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext aContext)
  {
    super.build(aContext);
    aContext.locale;
    final fams = ref.watch(famsProv).valueOrNull ?? const <FamDto>[];

    return ListView(
      key: const PageStorageKey('home.routine'),
      padding: tabPadding(aContext),
      children: [
        const TodayPlanBlock(),
        const SizedBox(height: _blockGap),
        const WorkTodayBlock(),
        const SizedBox(height: _blockGap),
        const StudyTodayBlock(),
        for (final fam in fams) ...[
          const SizedBox(height: _blockGap),
          FamilyTimelineCard(key: ValueKey('timeline:${fam.id}'), familyId: fam.id, title: fam.name),
        ],
        const SizedBox(height: _blockGap),
        const EnergyChartBlock(),
        const SizedBox(height: _blockGap),
        const NutritionTodayBlock(),
        const SizedBox(height: _blockGap),
        const StockTodayBlock(),
        const SizedBox(height: _blockGap),
        const TrainingPeopleBlock(),
      ],
    );
  }
}

class TrainingPeopleBlock extends ConsumerStatefulWidget
{
  const TrainingPeopleBlock({super.key});

  @override
  ConsumerState<TrainingPeopleBlock> createState() => _TrainingPeopleBlockState();
}

class _TrainingPeopleBlockState extends ConsumerState<TrainingPeopleBlock>
{
  String? _personId;
  int _generation = 0;

  Future<void> _open(String aPath) async
  {
    await context.push(aPath);
    if (mounted)
    {
      setState(() => _generation++);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final people = ref.watch(peopleProv).valueOrNull ?? const <PersonRef>[];
    final index = people.indexWhere((aPerson) => personQuery(aPerson) == _personId);
    final person = index < 0 ? null : people[index];
    final personId = personQuery(person);
    final canEdit = person?.canEdit ?? true;
    final tag = '${personId ?? 'me'}:$_generation';
    final Widget content = canEdit
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: NextWorkoutCard(key: ValueKey('next:$tag'), personId: personId, isBare: true),
              ),
              ProgramList(key: ValueKey('programs:$tag'), personId: personId, onOpen: _open),
            ],
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: PersonTrainingCard(key: ValueKey('person:$tag'), personId: person!.id, isBare: true),
          );

    return BlockCard(
      title: 'training.title'.tr(),
      onAdd: canEdit ? () => _open(newProgramPath(aPersonId: personId)) : null,
      addTooltip: 'training.new_program'.tr(),
      onExpand: () => _open(canEdit ? trainingPath(aPersonId: personId) : '/app/people/${person!.id}'),
      child: person == null
          ? content
          : PersonSwipe(
              people: people,
              index: index,
              onChanged: (aIndex) => setState(() => _personId = personQuery(people[aIndex])),
              child: content,
            ),
    );
  }
}

class ProgramList extends ConsumerStatefulWidget
{
  final String? personId;
  final Future<void> Function(String aPath) onOpen;

  const ProgramList({super.key, this.personId, required this.onOpen});

  @override
  ConsumerState<ProgramList> createState() => _ProgramListState();
}

class _ProgramListState extends ConsumerState<ProgramList>
{
  List<ProgramListItem>? _programs;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    try
    {
      final programs = await ref.read(apiProv).getPrograms(aPersonId: widget.personId);
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      programs.sort((aLeft, aRight) => (aRight.updatedTs ?? epoch).compareTo(aLeft.updatedTs ?? epoch));
      if (mounted)
      {
        setState(()
        {
          _programs = programs;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    ref.listen<int>(trainingRevisionProv, (_, __) => _load());
    final programs = _programs;
    if (_error != null)
    {
      return ErrorRetry(error: _error!, onRetry: _load);
    }
    if (programs == null)
    {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    if (programs.isEmpty)
    {
      return BlockEmpty('training.no_programs'.tr());
    }
    return Column(
      children: [
        for (final program in programs.take(_recentProgramCount))
          ListTile(
            onTap: () => widget.onOpen('/app/training/programs/${program.id}'),
            leading: Icon(
              program.isActive ? AppIcons.checkCircle : AppIcons.dumbbell,
              color: program.isActive ? aContext.palette.positive : aContext.palette.inkSecondary,
            ),
            title: Text(program.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              [
                'training.mode_${program.mode.name}'.tr(),
                'training.days_count'.plural(program.dayCount),
                if (program.isActive) 'training.active'.tr(),
              ].join(' · '),
            ),
            trailing: const Icon(AppIcons.chevronRight, size: 18),
          ),
      ],
    );
  }
}
