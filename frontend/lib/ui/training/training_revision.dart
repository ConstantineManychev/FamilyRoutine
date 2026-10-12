import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../routine/routine_style.dart';

final StateProvider<int> trainingRevisionProv = StateProvider<int>((aRef) => 0);

void notifyTrainingChanged(WidgetRef aRef)
{
  aRef.read(trainingRevisionProv.notifier).state++;
  aRef.read(routineRevisionProv.notifier).state++;
}
