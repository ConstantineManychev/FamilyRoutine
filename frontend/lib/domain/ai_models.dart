import 'finance_models.dart';

enum AiProvider
{
  anthropic('Anthropic', 'Claude', 'https://console.anthropic.com/settings/keys'),
  openai('OpenAI', 'ChatGPT', 'https://platform.openai.com/api-keys'),
  gemini('Google', 'Gemini', 'https://aistudio.google.com/apikey');

  final String company;
  final String product;
  final String keyUrl;

  const AiProvider(this.company, this.product, this.keyUrl);

  String get label => '$company ($product)';

  String toJson() => name;

  static AiProvider? parse(Object? aValue)
  {
    for (final provider in AiProvider.values)
    {
      if (provider.name == aValue)
      {
        return provider;
      }
    }
    return null;
  }
}

enum AiSource
{
  off,
  server,
  anthropic,
  openai,
  gemini;

  AiProvider? get ownProvider => AiProvider.parse(name);

  String toJson() => name;

  static AiSource fromProvider(AiProvider aProvider) => AiSource.values.byName(aProvider.name);

  static AiSource parse(Object? aValue)
  {
    for (final source in AiSource.values)
    {
      if (source.name == aValue)
      {
        return source;
      }
    }
    return AiSource.off;
  }
}

class AiModel
{
  final String id;
  final String name;

  const AiModel({required this.id, required this.name});

  factory AiModel.fromJson(Map<String, dynamic> aJson) => AiModel(id: aJson['id'] as String, name: aJson['name'] as String);

  static List<AiModel> listFromJson(Object? aJson) =>
      (aJson as List<dynamic>? ?? const []).map((aItem) => AiModel.fromJson(aItem as Map<String, dynamic>)).toList();
}

class AiKey
{
  final AiProvider provider;
  final String keyHint;
  final String model;
  final DateTime updatedTs;

  const AiKey({required this.provider, required this.keyHint, required this.model, required this.updatedTs});

  factory AiKey.fromJson(Map<String, dynamic> aJson) => AiKey(
        provider: AiProvider.parse(aJson['provider'])!,
        keyHint: aJson['key_hint'] as String,
        model: aJson['model'] as String,
        updatedTs: parseTs(aJson['updated_ts']),
      );
}

class AiKeySaved
{
  final AiKey key;
  final List<AiModel> models;

  const AiKeySaved({required this.key, required this.models});

  factory AiKeySaved.fromJson(Map<String, dynamic> aJson) => AiKeySaved(
        key: AiKey.fromJson(aJson['key'] as Map<String, dynamic>),
        models: AiModel.listFromJson(aJson['models']),
      );
}

class AiServer
{
  final AiProvider provider;
  final String model;
  final int dailyLimit;
  final int monthlyLimit;

  const AiServer({required this.provider, required this.model, required this.dailyLimit, required this.monthlyLimit});

  factory AiServer.fromJson(Map<String, dynamic> aJson) => AiServer(
        provider: AiProvider.parse(aJson['provider'])!,
        model: aJson['model'] as String,
        dailyLimit: aJson['daily_limit'] as int,
        monthlyLimit: aJson['monthly_limit'] as int,
      );
}

class AiUsage
{
  final bool isOwnKey;
  final int todayCount;
  final int monthCount;
  final int monthInputTokens;
  final int monthOutputTokens;

  const AiUsage({
    required this.isOwnKey,
    required this.todayCount,
    required this.monthCount,
    required this.monthInputTokens,
    required this.monthOutputTokens,
  });

  static const AiUsage empty = AiUsage(isOwnKey: false, todayCount: 0, monthCount: 0, monthInputTokens: 0, monthOutputTokens: 0);

  factory AiUsage.fromJson(Map<String, dynamic> aJson) => AiUsage(
        isOwnKey: aJson['is_own_key'] as bool,
        todayCount: aJson['today_count'] as int,
        monthCount: aJson['month_count'] as int,
        monthInputTokens: aJson['month_input_tokens'] as int,
        monthOutputTokens: aJson['month_output_tokens'] as int,
      );
}

class AiSettings
{
  final AiSource source;
  final int? dailyLimit;
  final int? monthlyLimit;
  final int effectiveDailyLimit;
  final int effectiveMonthlyLimit;
  final AiServer? server;
  final bool isOwnKeysAllowed;
  final List<AiKey> keys;
  final List<AiUsage> usage;

  const AiSettings({
    required this.source,
    required this.dailyLimit,
    required this.monthlyLimit,
    required this.effectiveDailyLimit,
    required this.effectiveMonthlyLimit,
    required this.server,
    required this.isOwnKeysAllowed,
    required this.keys,
    required this.usage,
  });

  factory AiSettings.fromJson(Map<String, dynamic> aJson) => AiSettings(
        source: AiSource.parse(aJson['source']),
        dailyLimit: aJson['daily_limit'] as int?,
        monthlyLimit: aJson['monthly_limit'] as int?,
        effectiveDailyLimit: aJson['effective_daily_limit'] as int,
        effectiveMonthlyLimit: aJson['effective_monthly_limit'] as int,
        server: aJson['server'] == null ? null : AiServer.fromJson(aJson['server'] as Map<String, dynamic>),
        isOwnKeysAllowed: aJson['is_own_keys_allowed'] as bool,
        keys: (aJson['keys'] as List<dynamic>).map((aItem) => AiKey.fromJson(aItem as Map<String, dynamic>)).toList(),
        usage: (aJson['usage'] as List<dynamic>).map((aItem) => AiUsage.fromJson(aItem as Map<String, dynamic>)).toList(),
      );

  AiKey? keyOf(AiProvider aProvider)
  {
    for (final key in keys)
    {
      if (key.provider == aProvider)
      {
        return key;
      }
    }
    return null;
  }

  AiUsage get currentUsage
  {
    final isOwn = source.ownProvider != null;
    for (final item in usage)
    {
      if (item.isOwnKey == isOwn)
      {
        return item;
      }
    }
    return AiUsage.empty;
  }
}

class AiFeatures
{
  final bool isReceiptRecognition;
  final AiProvider? provider;

  const AiFeatures({required this.isReceiptRecognition, required this.provider});

  static const AiFeatures none = AiFeatures(isReceiptRecognition: false, provider: null);

  factory AiFeatures.fromJson(Map<String, dynamic> aJson) => AiFeatures(
        isReceiptRecognition: aJson['is_receipt_recognition'] as bool? ?? false,
        provider: AiProvider.parse(aJson['recognition_provider']),
      );
}
