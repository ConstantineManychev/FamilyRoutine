import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';

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

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'exercises.title'.tr(),
            actions: [
              ElevatedButton.icon(
                onPressed: () => aContext.go('/app/exercises/new'),
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('exercises.add'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: exercisesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(exercisesProv)),
              data: (aExercises) => aExercises.isEmpty
                  ? Center(child: Text('common.no_data'.tr()))
                  : ListView.builder(
                      itemCount: aExercises.length,
                      itemBuilder: (_, aIndex)
                      {
                        final ex = aExercises[aIndex];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            leading: Icon(
                              ex.isCustom ? AppIcons.user : AppIcons.activity,
                              color: Colors.blue,
                            ),
                            title: Text(ex.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('${'exercises.types.${ex.exType}'.tr()} · MET ${ex.metVal}'),
                            trailing: const Icon(AppIcons.chevronRight),
                            onTap: () => aContext.go('/app/exercises/${ex.id}'),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
