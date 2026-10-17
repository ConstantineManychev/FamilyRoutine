import 'finance_models.dart';

enum StudyUnit
{
  percent,
  pages,
  tasks,
  lessons,
  chapters,
  hours;

  static StudyUnit parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => StudyUnit.percent);

  static StudyUnit? parseOrNull(Object? aValue)
  {
    for (final unit in values)
    {
      if (unit.name == aValue)
      {
        return unit;
      }
    }
    return null;
  }
}

class StudyProgress
{
  final double percent;
  final double? done;
  final double? target;
  final StudyUnit? unit;
  final bool isAggregated;

  const StudyProgress({this.percent = 0, this.done, this.target, this.unit, this.isAggregated = false});

  bool get isComplete => percent >= 100;

  factory StudyProgress.fromJson(Object? aJson)
  {
    if (aJson is! Map<String, dynamic>)
    {
      return const StudyProgress();
    }
    return StudyProgress(
      percent: parseDecimal(aJson['percent']),
      done: parseDecimalOrNull(aJson['done']),
      target: parseDecimalOrNull(aJson['target']),
      unit: StudyUnit.parseOrNull(aJson['unit']),
      isAggregated: aJson['is_aggregated'] as bool? ?? false,
    );
  }
}

class StudyTopic
{
  final String id;
  final String? parentId;
  final String title;
  final String? description;
  final StudyUnit unit;
  final double target;
  final double done;
  final int depth;
  final int childCount;
  final int noteCount;
  final StudyProgress progress;
  final DateTime updatedTs;

  const StudyTopic({
    required this.id,
    this.parentId,
    required this.title,
    this.description,
    this.unit = StudyUnit.percent,
    this.target = 100,
    this.done = 0,
    this.depth = 1,
    this.childCount = 0,
    this.noteCount = 0,
    this.progress = const StudyProgress(),
    required this.updatedTs,
  });

  bool get hasChildren => childCount > 0;

  factory StudyTopic.fromJson(Map<String, dynamic> aJson) => StudyTopic(
        id: aJson['id'] as String,
        parentId: aJson['parent_id'] as String?,
        title: aJson['title'] as String? ?? '',
        description: aJson['description'] as String?,
        unit: StudyUnit.parse(aJson['unit']),
        target: parseDecimal(aJson['target']),
        done: parseDecimal(aJson['done']),
        depth: (aJson['depth'] as num?)?.toInt() ?? 1,
        childCount: (aJson['child_count'] as num?)?.toInt() ?? 0,
        noteCount: (aJson['note_count'] as num?)?.toInt() ?? 0,
        progress: StudyProgress.fromJson(aJson['progress']),
        updatedTs: parseTs(aJson['updated_ts']),
      );
}

class StudyTree
{
  final int maxDepth;
  final List<StudyTopic> topics;

  const StudyTree({this.maxDepth = 5, this.topics = const []});

  factory StudyTree.fromJson(Map<String, dynamic> aJson) => StudyTree(
        maxDepth: (aJson['max_depth'] as num?)?.toInt() ?? 5,
        topics: (aJson['topics'] as List? ?? const [])
            .map((aItem) => StudyTopic.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  StudyTopic? byId(String? aId) => topics.where((aTopic) => aTopic.id == aId).firstOrNull;

  List<StudyTopic> get roots => topics.where((aTopic) => aTopic.parentId == null).toList();

  List<StudyTopic> childrenOf(String aId) => topics.where((aTopic) => aTopic.parentId == aId).toList();

  List<StudyTopic> pathTo(String aId)
  {
    final path = <StudyTopic>[];
    final seen = <String>{};
    var current = byId(aId);
    while (current != null && seen.add(current.id))
    {
      path.insert(0, current);
      current = byId(current.parentId);
    }
    return path;
  }

  Set<String> branchIds(String aId)
  {
    final ids = <String>{aId};
    var frontier = [aId];
    while (frontier.isNotEmpty)
    {
      final next = [
        for (final topic in topics)
          if (topic.parentId != null && frontier.contains(topic.parentId) && ids.add(topic.id)) topic.id,
      ];
      frontier = next;
    }
    return ids;
  }

  int heightOf(String aId)
  {
    final depth = byId(aId)?.depth ?? 1;
    return branchIds(aId).map((aBranchId) => (byId(aBranchId)?.depth ?? depth) - depth + 1).fold(1, (aMax, aValue) => aValue > aMax ? aValue : aMax);
  }

  bool canAddChild(StudyTopic? aParent) => (aParent?.depth ?? 0) < maxDepth;

  bool canMoveUnder(String aId, StudyTopic? aParent)
  {
    if (aParent != null && branchIds(aId).contains(aParent.id))
    {
      return false;
    }
    return (aParent?.depth ?? 0) + heightOf(aId) <= maxDepth;
  }

  List<StudyTopic> depthFirst()
  {
    final ordered = <StudyTopic>[];
    void visit(StudyTopic aTopic)
    {
      ordered.add(aTopic);
      for (final child in childrenOf(aTopic.id))
      {
        visit(child);
      }
    }

    for (final root in roots)
    {
      visit(root);
    }
    return ordered;
  }
}

class StudyNote
{
  final String id;
  final String topicId;
  final List<String> topicPath;
  final String body;
  final DateTime noteTs;
  final DateTime createdTs;
  final DateTime updatedTs;

  const StudyNote({
    required this.id,
    required this.topicId,
    this.topicPath = const [],
    required this.body,
    required this.noteTs,
    required this.createdTs,
    required this.updatedTs,
  });

  factory StudyNote.fromJson(Map<String, dynamic> aJson) => StudyNote(
        id: aJson['id'] as String,
        topicId: aJson['topic_id'] as String,
        topicPath: (aJson['topic_path'] as List? ?? const []).cast<String>(),
        body: aJson['body'] as String? ?? '',
        noteTs: parseTs(aJson['note_ts']),
        createdTs: parseTs(aJson['created_ts']),
        updatedTs: parseTs(aJson['updated_ts']),
      );

  List<String> sourceRelativeTo(int aDepth) => topicPath.length > aDepth ? topicPath.sublist(aDepth) : const [];
}

class MarkStudy
{
  final List<StudyTopic> topics;
  final List<StudyNote> notes;

  const MarkStudy({this.topics = const [], this.notes = const []});

  factory MarkStudy.fromJson(Map<String, dynamic> aJson) => MarkStudy(
        topics: (aJson['topics'] as List? ?? const [])
            .map((aItem) => StudyTopic.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        notes: (aJson['notes'] as List? ?? const [])
            .map((aItem) => StudyNote.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class TopicDraft
{
  final String? parentId;
  final String title;
  final String? description;
  final StudyUnit unit;
  final double target;
  final double done;

  const TopicDraft({this.parentId, required this.title, this.description, required this.unit, required this.target, required this.done});

  factory TopicDraft.of(StudyTopic aTopic) => TopicDraft(
        parentId: aTopic.parentId,
        title: aTopic.title,
        description: aTopic.description,
        unit: aTopic.unit,
        target: aTopic.target,
        done: aTopic.done,
      );

  TopicDraft copyWith({String? parentId, bool isRoot = false, double? done}) => TopicDraft(
        parentId: isRoot ? null : parentId ?? this.parentId,
        title: title,
        description: description,
        unit: unit,
        target: target,
        done: done ?? this.done,
      );

  Map<String, dynamic> toJson()
  {
    final description = this.description?.trim();
    return {
      'parent_id': parentId,
      'title': title.trim(),
      'description': description == null || description.isEmpty ? null : description,
      'unit': unit.name,
      'target': (unit == StudyUnit.percent ? 100 : target).toString(),
      'done': done.toString(),
    };
  }
}
