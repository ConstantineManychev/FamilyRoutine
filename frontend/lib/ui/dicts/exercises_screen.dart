import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../training/training_format.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/app_theme.dart';

final AutoDisposeFutureProvider<List<DictExDto>> exercisesProv = FutureProvider.autoDispose<List<DictExDto>>((aRef) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getExercises();
});

class ExercisesScreen extends ConsumerWidget
{
  const ExercisesScreen({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final exercisesAsync = aRef.watch(exercisesProv);

    return ListPage(
      title: 'exercises.title'.tr(),
      onAdd: () => aContext.push('/app/exercises/new'),
      addTooltip: 'exercises.add'.tr(),
      builder: (_, aQuery) => exercisesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(exercisesProv)),
        data: (aExercises)
        {
          final shown = aExercises.where((aEx) => aQuery.isEmpty || exerciseDisplayName(aEx).toLowerCase().contains(aQuery)).toList();
          if (shown.isEmpty)
          {
            return Center(child: Text('common.no_data'.tr()));
          }
          return ListView.builder(
            key: const PageStorageKey('list.exercises'),
            padding: screenPadding(aContext),
            itemCount: shown.length,
            itemBuilder: (_, aIndex)
            {
              final ex = shown[aIndex];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Icon(ex.isCustom ? AppIcons.user : AppIcons.activity, color: aContext.colors.primary),
                  title: Text(exerciseDisplayName(ex), style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${'exercises.types.${ex.exType}'.tr()} · MET ${ex.metVal}'),
                  trailing: const Icon(AppIcons.chevronRight),
                  onTap: () => aContext.push('/app/exercises/${ex.id}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
