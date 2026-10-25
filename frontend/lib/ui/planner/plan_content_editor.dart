import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../dicts/product_cats.dart';
import '../nutrition/add_food_screen.dart';
import '../nutrition/nutrition_format.dart';

const int _maxTaskLen = 200;
const int _maxStudyNoteLen = 2000;

String planFoodTitle(ProductCatTree? aTree, {String? aCatId, String? aTitle})
{
  final cat = aTree?[aCatId];
  if (cat != null)
  {
    return catLabel(cat);
  }
  return aTitle ?? 'nutrition.quick_title'.tr();
}

String planFoodKcal(BuildContext aContext, double aKcal, {bool aIsEstimate = false}) =>
    aIsEstimate ? '≈ ${formatKcal(aContext, aKcal)}' : formatKcal(aContext, aKcal);

String planCatLine(BuildContext aContext, double? aGrams, {bool aIsMl = false}) =>
    'planner.food_from_cat'.tr(args: [formatGrams(aContext, aGrams ?? 0, aIsMl: aIsMl)]);

class PlanFoodDraft
{
  final String title;
  final double kcal;
  final Map<String, dynamic> payload;

  const PlanFoodDraft({required this.title, required this.kcal, required this.payload});

  String? get catId => payload['cat_id'] as String?;

  double? get grams => double.tryParse('${payload['grams']}');

  factory PlanFoodDraft.of(PlanFood aFood) => PlanFoodDraft(
        title: aFood.title ?? 'nutrition.quick_title'.tr(),
        kcal: aFood.total.kcal,
        payload: aFood.input,
      );

  factory PlanFoodDraft.picked(PickedFood aFood) => PlanFoodDraft(title: aFood.title, kcal: aFood.kcal, payload: aFood.payload);
}

class PlanStudyDraft
{
  final String topicId;
  final String topicTitle;
  final String? note;

  const PlanStudyDraft({required this.topicId, required this.topicTitle, this.note});
}

class PlanContentDraft
{
  final List<PlanFoodDraft> foods;
  final List<String> tasks;
  final List<PlanStudyDraft> studies;

  PlanContentDraft({List<PlanFoodDraft>? aFoods, List<String>? aTasks, List<PlanStudyDraft>? aStudies})
      : foods = aFoods ?? [],
        tasks = aTasks ?? [],
        studies = aStudies ?? [];

  factory PlanContentDraft.of(PlanContent aContent) => PlanContentDraft(
        aFoods: aContent.foods.map(PlanFoodDraft.of).toList(),
        aTasks: aContent.tasks.map((aTask) => aTask.title).toList(),
        aStudies: aContent.studies
            .map((aStudy) => PlanStudyDraft(topicId: aStudy.topicId, topicTitle: aStudy.topicTitle, note: aStudy.note))
            .toList(),
      );

  double get kcal => foods.fold(0, (aSum, aFood) => aSum + aFood.kcal);

  Map<String, dynamic> toJson(RoutineStatus? aCategory) => {
        'foods': aCategory == RoutineStatus.meal ? foods.map((aFood) => aFood.payload).toList() : const [],
        'tasks': aCategory == RoutineStatus.work ? tasks.map((aTitle) => {'title': aTitle}).toList() : const [],
        'studies': aCategory == RoutineStatus.school
            ? studies.map((aStudy) => {'topic_id': aStudy.topicId, if (aStudy.note != null) 'note': aStudy.note}).toList()
            : const [],
      };
}

bool hasPlanContent(RoutineStatus? aCategory) =>
    aCategory == RoutineStatus.meal || aCategory == RoutineStatus.work || aCategory == RoutineStatus.school;

class PlanContentEditor extends ConsumerStatefulWidget
{
  final RoutineStatus? category;
  final PlanContentDraft draft;
  final String? personId;
  final bool isEnabled;

  const PlanContentEditor({super.key, required this.category, required this.draft, this.personId, this.isEnabled = true});

  @override
  ConsumerState<PlanContentEditor> createState() => _PlanContentEditorState();
}

class _PlanContentEditorState extends ConsumerState<PlanContentEditor>
{
  final _taskCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  StudyTree? _tree;
  String? _topicId;

  @override
  void initState()
  {
    super.initState();
    if (widget.category == RoutineStatus.school)
    {
      _loadTopics();
    }
  }

  @override
  void didUpdateWidget(covariant PlanContentEditor aOldWidget)
  {
    super.didUpdateWidget(aOldWidget);
    if (widget.category == RoutineStatus.school && _tree == null)
    {
      _loadTopics();
    }
  }

  @override
  void dispose()
  {
    _taskCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTopics() async
  {
    try
    {
      final tree = await ref.read(apiProv).getStudyTree();
      if (mounted)
      {
        setState(() => _tree = tree);
      }
    }
    catch (_)
    {
      if (mounted)
      {
        setState(() => _tree = const StudyTree());
      }
    }
  }

  Future<void> _addFood() async
  {
    final picked = await pickPlanFood(context, aPersonId: widget.personId);
    if (picked != null && mounted)
    {
      setState(() => widget.draft.foods.add(PlanFoodDraft.picked(picked)));
    }
  }

  void _addTask()
  {
    final title = _taskCtrl.text.trim();
    if (title.isEmpty)
    {
      return;
    }
    setState(()
    {
      widget.draft.tasks.add(title);
      _taskCtrl.clear();
    });
  }

  void _addStudy()
  {
    final topic = _tree?.byId(_topicId);
    if (topic == null)
    {
      return;
    }
    final note = _noteCtrl.text.trim();
    setState(()
    {
      widget.draft.studies.add(PlanStudyDraft(topicId: topic.id, topicTitle: topic.title, note: note.isEmpty ? null : note));
      _noteCtrl.clear();
      _topicId = null;
    });
  }

  Widget _heading(BuildContext aContext, String aKey, {String? aTrailing})
  {
    final palette = aContext.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(child: Text(aKey.tr(), style: const TextStyle(fontWeight: FontWeight.w700))),
          if (aTrailing != null) Text(aTrailing, style: TextStyle(color: palette.inkSecondary)),
        ],
      ),
    );
  }

  Widget _row({required Key aKey, required String aTitle, String? aSubtitle, String? aTrailing, required VoidCallback aOnRemove})
  {
    return ListTile(
      key: aKey,
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(aTitle),
      subtitle: aSubtitle == null ? null : Text(aSubtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (aTrailing != null) Text(aTrailing),
          IconButton(
            tooltip: 'common.delete'.tr(),
            icon: const Icon(AppIcons.x, size: 18),
            onPressed: widget.isEnabled ? aOnRemove : null,
          ),
        ],
      ),
    );
  }

  Widget _foods(BuildContext aContext)
  {
    final draft = widget.draft;
    final tree = ref.watch(productCatsProv).valueOrNull;
    final hasEstimate = draft.foods.any((aFood) => aFood.catId != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(aContext, 'planner.content_food', aTrailing: planFoodKcal(aContext, draft.kcal, aIsEstimate: hasEstimate)),
        for (var index = 0; index < draft.foods.length; index++)
          _row(
            aKey: ValueKey('plan.food.$index'),
            aTitle: planFoodTitle(tree, aCatId: draft.foods[index].catId, aTitle: draft.foods[index].title),
            aSubtitle: draft.foods[index].catId == null ? null : planCatLine(aContext, draft.foods[index].grams),
            aTrailing: planFoodKcal(aContext, draft.foods[index].kcal, aIsEstimate: draft.foods[index].catId != null),
            aOnRemove: () => setState(() => draft.foods.removeAt(index)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('plan.add_food'),
            onPressed: widget.isEnabled ? _addFood : null,
            icon: const Icon(AppIcons.plus, size: 18),
            label: Text('planner.add_food'.tr()),
          ),
        ),
      ],
    );
  }

  Widget _tasks(BuildContext aContext)
  {
    final draft = widget.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(aContext, 'planner.content_tasks'),
        for (var index = 0; index < draft.tasks.length; index++)
          _row(
            aKey: ValueKey('plan.task.$index'),
            aTitle: draft.tasks[index],
            aOnRemove: () => setState(() => draft.tasks.removeAt(index)),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('plan.task_field'),
                controller: _taskCtrl,
                enabled: widget.isEnabled,
                inputFormatters: [LengthLimitingTextInputFormatter(_maxTaskLen)],
                onSubmitted: (_) => _addTask(),
                decoration: InputDecoration(labelText: 'planner.task_hint'.tr(), border: const OutlineInputBorder(), isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              key: const ValueKey('plan.add_task'),
              tooltip: 'planner.add_task'.tr(),
              onPressed: widget.isEnabled ? _addTask : null,
              icon: const Icon(AppIcons.plus),
            ),
          ],
        ),
      ],
    );
  }

  Widget _studies(BuildContext aContext)
  {
    final draft = widget.draft;
    final tree = _tree;
    final palette = aContext.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(aContext, 'planner.content_study'),
        for (var index = 0; index < draft.studies.length; index++)
          _row(
            aKey: ValueKey('plan.study.$index'),
            aTitle: draft.studies[index].topicTitle,
            aSubtitle: draft.studies[index].note,
            aOnRemove: () => setState(() => draft.studies.removeAt(index)),
          ),
        if (tree == null)
          const LinearProgressIndicator()
        else if (tree.topics.isEmpty)
          Text('planner.no_topics'.tr(), style: TextStyle(color: palette.inkMuted))
        else ...[
          DropdownButtonFormField<String>(
            key: ValueKey('plan.topic.${draft.studies.length}'),
            initialValue: _topicId,
            isExpanded: true,
            decoration: InputDecoration(labelText: 'planner.study_topic'.tr(), border: const OutlineInputBorder(), isDense: true),
            items: [
              for (final topic in tree.topics)
                DropdownMenuItem(
                  value: topic.id,
                  child: Padding(
                    padding: EdgeInsets.only(left: 12.0 * topic.depth),
                    child: Text(topic.title, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
            onChanged: widget.isEnabled ? (aValue) => setState(() => _topicId = aValue) : null,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('plan.study_note'),
            controller: _noteCtrl,
            enabled: widget.isEnabled,
            minLines: 1,
            maxLines: 3,
            inputFormatters: [LengthLimitingTextInputFormatter(_maxStudyNoteLen)],
            decoration: InputDecoration(labelText: 'planner.study_note'.tr(), border: const OutlineInputBorder(), isDense: true),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('plan.add_study'),
              onPressed: widget.isEnabled && _topicId != null ? _addStudy : null,
              icon: const Icon(AppIcons.plus, size: 18),
              label: Text('planner.add_study'.tr()),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    return switch (widget.category)
    {
      RoutineStatus.meal => _foods(aContext),
      RoutineStatus.work => _tasks(aContext),
      RoutineStatus.school => _studies(aContext),
      _ => const SizedBox.shrink(),
    };
  }
}
