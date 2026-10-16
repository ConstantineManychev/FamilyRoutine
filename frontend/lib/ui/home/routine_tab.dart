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
import '../planner/planner_screen.dart';
import '../nutrition/nutrition_today_block.dart';
import '../routine/family_timeline_card.dart';
import '../training/next_workout_card.dart';
import '../training/training_revision.dart';

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
        for (final fam in fams) ...[
          const SizedBox(height: _blockGap),
          FamilyTimelineCard(key: ValueKey('timeline:${fam.id}'), familyId: fam.id, title: fam.name),
        ],
        const SizedBox(height: _blockGap),
        const NutritionTodayBlock(),
        const SizedBox(height: _blockGap),
        const NextWorkoutCard(),
        const SizedBox(height: _blockGap),
        const ProgramsBlock(),
      ],
    );
  }
}

class ProgramsBlock extends ConsumerStatefulWidget
{
  const ProgramsBlock({super.key});

  @override
  ConsumerState<ProgramsBlock> createState() => _ProgramsBlockState();
}

class _ProgramsBlockState extends ConsumerState<ProgramsBlock>
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
      final programs = await ref.read(apiProv).getPrograms();
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

  Future<void> _open(String aPath) async
  {
    await context.push(aPath);
    await _load();
  }

  @override
  Widget build(BuildContext aContext)
  {
    ref.listen<int>(trainingRevisionProv, (_, __) => _load());
    final programs = _programs;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (programs == null)
    {
      content = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else if (programs.isEmpty)
    {
      content = BlockEmpty('training.no_programs'.tr());
    }
    else
    {
      content = Column(
        children: [
          for (final program in programs.take(_recentProgramCount))
            ListTile(
              onTap: () => _open('/app/training/programs/${program.id}'),
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

    return BlockCard(
      title: 'training.programs'.tr(),
      onAdd: () => _open('/app/training/programs/new'),
      addTooltip: 'training.new_program'.tr(),
      onExpand: () => _open('/app/training'),
      child: content,
    );
  }
}
