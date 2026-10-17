import 'finance_models.dart';
import 'stock_models.dart';

enum NotifyKind
{
  plan,
  workout,
  expiring,
  expired;

  static NotifyKind parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => NotifyKind.plan);

  bool get isStock => this == NotifyKind.expiring || this == NotifyKind.expired;
}

class NotifySettings
{
  final String tz;
  final String lang;
  final bool isPlan;
  final int planLeadMin;
  final bool isWorkout;
  final int workoutLeadMin;
  final bool isExpiring;
  final bool isExpired;
  final bool isWebPush;
  final int pushSubs;

  const NotifySettings({
    this.tz = 'UTC',
    this.lang = 'en',
    this.isPlan = true,
    this.planLeadMin = 15,
    this.isWorkout = true,
    this.workoutLeadMin = 60,
    this.isExpiring = true,
    this.isExpired = true,
    this.isWebPush = false,
    this.pushSubs = 0,
  });

  factory NotifySettings.fromJson(Map<String, dynamic> aJson) => NotifySettings(
        tz: aJson['tz'] as String? ?? 'UTC',
        lang: aJson['lang'] as String? ?? 'en',
        isPlan: aJson['is_plan'] as bool? ?? true,
        planLeadMin: (aJson['plan_lead_min'] as num?)?.toInt() ?? 15,
        isWorkout: aJson['is_workout'] as bool? ?? true,
        workoutLeadMin: (aJson['workout_lead_min'] as num?)?.toInt() ?? 60,
        isExpiring: aJson['is_expiring'] as bool? ?? true,
        isExpired: aJson['is_expired'] as bool? ?? true,
        isWebPush: aJson['is_web_push'] as bool? ?? false,
        pushSubs: (aJson['push_subs'] as num?)?.toInt() ?? 0,
      );
}

class NoticeStockLine
{
  final String title;
  final double qty;
  final StockMeasure measure;

  const NoticeStockLine({required this.title, required this.qty, required this.measure});

  factory NoticeStockLine.fromJson(Map<String, dynamic> aJson) => NoticeStockLine(
        title: aJson['title'] as String? ?? '',
        qty: parseDecimal(aJson['qty']),
        measure: StockMeasure.parse(aJson['measure']),
      );
}

class NoticeContent
{
  final NotifyKind kind;
  final String title;
  final String body;
  final String link;
  final Map<String, dynamic> params;

  const NoticeContent({required this.kind, required this.title, required this.body, required this.link, this.params = const {}});

  String? get eventTitle => params['title'] as String?;

  DateTime? get startTs => parseTsOrNull(params['start_ts']);

  bool get isToday => params['day'] == 'today';

  String? get familyName => params['family_name'] as String?;

  int get more => (params['more'] as num?)?.toInt() ?? 0;

  List<NoticeStockLine> get lines => (params['items'] as List? ?? const [])
      .map((aItem) => NoticeStockLine.fromJson(aItem as Map<String, dynamic>))
      .toList();

  static Map<String, dynamic> paramsOf(Object? aValue) => aValue is Map<String, dynamic> ? aValue : const {};
}

class AppNotice extends NoticeContent
{
  final String id;
  final DateTime createdTs;
  final bool isRead;

  const AppNotice({
    required this.id,
    required super.kind,
    required super.title,
    required super.body,
    required super.link,
    super.params,
    required this.createdTs,
    this.isRead = false,
  });

  factory AppNotice.fromJson(Map<String, dynamic> aJson) => AppNotice(
        id: aJson['id'] as String,
        kind: NotifyKind.parse(aJson['kind']),
        title: aJson['title'] as String? ?? '',
        body: aJson['body'] as String? ?? '',
        link: aJson['link'] as String? ?? '/app',
        params: NoticeContent.paramsOf(aJson['params']),
        createdTs: parseTs(aJson['created_ts']),
        isRead: aJson['is_read'] as bool? ?? false,
      );

  AppNotice markedRead() => AppNotice(
        id: id,
        kind: kind,
        title: title,
        body: body,
        link: link,
        params: params,
        createdTs: createdTs,
        isRead: true,
      );
}

class NoticeInbox
{
  final List<AppNotice> items;
  final int unread;

  const NoticeInbox({this.items = const [], this.unread = 0});

  factory NoticeInbox.fromJson(Map<String, dynamic> aJson) => NoticeInbox(
        items: (aJson['items'] as List? ?? const [])
            .map((aItem) => AppNotice.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        unread: (aJson['unread'] as num?)?.toInt() ?? 0,
      );
}

class UpcomingNotice extends NoticeContent
{
  final String key;
  final DateTime dueTs;

  const UpcomingNotice({
    required this.key,
    required this.dueTs,
    required super.kind,
    required super.title,
    required super.body,
    required super.link,
    super.params,
  });

  factory UpcomingNotice.fromJson(Map<String, dynamic> aJson) => UpcomingNotice(
        key: aJson['key'] as String? ?? '',
        dueTs: parseTs(aJson['due_ts']),
        kind: NotifyKind.parse(aJson['kind']),
        title: aJson['title'] as String? ?? '',
        body: aJson['body'] as String? ?? '',
        link: aJson['link'] as String? ?? '/app',
        params: NoticeContent.paramsOf(aJson['params']),
      );
}
