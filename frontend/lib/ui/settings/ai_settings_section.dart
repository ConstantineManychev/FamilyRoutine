import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';

const int _maxDailyLimit = 1000;
const int _maxMonthlyLimit = 30000;
const double _contentMaxWidth = 760;
const Color _borderColor = Color(0xFFE5E7EB);

class AiSettingsSection extends ConsumerStatefulWidget
{
  const AiSettingsSection({super.key});

  @override
  ConsumerState<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends ConsumerState<AiSettingsSection>
{
  final Map<AiProvider, TextEditingController> _keyCtrls = {
    for (final provider in AiProvider.values) provider: TextEditingController(),
  };
  final Map<AiProvider, List<AiModel>> _models = {};
  final Set<AiProvider> _replacing = {};
  final _dailyCtrl = TextEditingController();
  final _monthlyCtrl = TextEditingController();
  AiSettings? _settings;
  Object? _loadError;
  bool _isBusy = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    for (final ctrl in _keyCtrls.values)
    {
      ctrl.dispose();
    }
    _dailyCtrl.dispose();
    _monthlyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    setState(() => _loadError = null);
    try
    {
      _apply(await ref.read(apiProv).getAiSettings());
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
  }

  void _apply(AiSettings aSettings)
  {
    if (!mounted)
    {
      return;
    }
    setState(()
    {
      _settings = aSettings;
      _dailyCtrl.text = aSettings.dailyLimit?.toString() ?? '';
      _monthlyCtrl.text = aSettings.monthlyLimit?.toString() ?? '';
    });
    ref.invalidate(aiFeaturesProv);
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  int? _limitValue(TextEditingController aCtrl) => int.tryParse(aCtrl.text.trim());

  Future<void> _saveSettings(AiSource aSource) async
  {
    await _run(() async
    {
      _apply(await ref.read(apiProv).saveAiSettings(aSource, _limitValue(_dailyCtrl), _limitValue(_monthlyCtrl)));
    });
  }

  Future<void> _saveLimits() async
  {
    final settings = _settings;
    if (settings == null)
    {
      return;
    }
    await _saveSettings(settings.source);
    if (mounted)
    {
      showInfoSnack(context, 'ai.saved'.tr());
    }
  }

  Future<void> _saveKey(AiProvider aProvider) async
  {
    final key = _keyCtrls[aProvider]!.text.trim();
    if (key.isEmpty)
    {
      return;
    }

    await _run(() async
    {
      final saved = await ref.read(apiProv).saveAiKey(aProvider, key);
      _keyCtrls[aProvider]!.clear();
      _models[aProvider] = saved.models;
      _replacing.remove(aProvider);
      _apply(await ref.read(apiProv).getAiSettings());
      if (mounted)
      {
        showInfoSnack(context, 'ai.key_checked'.tr(args: [saved.key.model]));
      }
    });
  }

  Future<void> _loadModels(AiProvider aProvider) async
  {
    await _run(() async
    {
      final models = await ref.read(apiProv).getAiModels(aProvider);
      if (mounted)
      {
        setState(() => _models[aProvider] = models);
      }
    });
  }

  Future<void> _setModel(AiProvider aProvider, String? aModel) async
  {
    if (aModel == null)
    {
      return;
    }
    await _run(() async
    {
      final key = await ref.read(apiProv).setAiModel(aProvider, aModel);
      _apply(await ref.read(apiProv).getAiSettings());
      if (mounted)
      {
        showInfoSnack(context, 'ai.model_saved'.tr(args: [key.model]));
      }
    });
  }

  Future<void> _deleteKey(AiProvider aProvider) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'ai.delete_key'.tr(),
      aMessage: 'ai.delete_confirm'.tr(args: [aProvider.label]),
    );
    if (!isConfirmed)
    {
      return;
    }

    await _run(() async
    {
      await ref.read(apiProv).deleteAiKey(aProvider);
      _models.remove(aProvider);
      _apply(await ref.read(apiProv).getAiSettings());
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    final settings = _settings;
    if (settings == null)
    {
      return _loadError != null
          ? ErrorRetry(error: _loadError!, onRetry: _load)
          : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ai.title'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('ai.intro'.tr(), style: const TextStyle(color: inkSecondary)),
            const SizedBox(height: 16),
            _buildSourceCard(settings),
            const SizedBox(height: 24),
            Text('ai.keys_title'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              settings.isOwnKeysAllowed ? 'ai.keys_hint'.tr() : 'ai.own_disabled'.tr(),
              style: const TextStyle(color: inkSecondary),
            ),
            const SizedBox(height: 12),
            if (settings.isOwnKeysAllowed)
              for (final provider in AiProvider.values) ...[
                _buildKeyCard(provider, settings.keyOf(provider)),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 12),
            _buildLimitsCard(settings),
            if (_isBusy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }

  Widget _card(List<Widget> aChildren)
  {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: aChildren),
      ),
    );
  }

  Widget _buildSourceCard(AiSettings aSettings)
  {
    final server = aSettings.server;

    return _card([
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text('ai.source_title'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      RadioGroup<AiSource>(
        groupValue: aSettings.source,
        onChanged: (aSource)
        {
          if (aSource != null && !_isBusy)
          {
            _saveSettings(aSource);
          }
        },
        child: Column(
          children: [
            RadioListTile<AiSource>(value: AiSource.off, title: Text('ai.source_off'.tr())),
            if (server != null)
              RadioListTile<AiSource>(
                value: AiSource.server,
                title: Text('ai.source_server'.tr()),
                subtitle: Text('ai.server_hint'.tr(args: [
                  server.provider.label,
                  server.model,
                  '${server.dailyLimit}',
                  '${server.monthlyLimit}',
                ])),
              ),
            if (aSettings.isOwnKeysAllowed)
              for (final provider in AiProvider.values)
                RadioListTile<AiSource>(
                  value: AiSource.fromProvider(provider),
                  enabled: aSettings.keyOf(provider) != null,
                  title: Text('ai.source_own'.tr(args: [provider.label])),
                  subtitle: Text(aSettings.keyOf(provider)?.model ?? 'ai.add_key_first'.tr()),
                ),
          ],
        ),
      ),
    ]);
  }

  Widget _buildKeyCard(AiProvider aProvider, AiKey? aKey)
  {
    final isEditing = aKey == null || _replacing.contains(aProvider);

    return _card([
      ListTile(
        leading: const Icon(AppIcons.keyRound),
        title: Text(aProvider.label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(aKey == null ? 'ai.no_key'.tr() : 'ai.key_saved'.tr(args: [aKey.keyHint])),
        trailing: TextButton.icon(
          onPressed: () => launchUrl(Uri.parse(aProvider.keyUrl)),
          icon: const Icon(AppIcons.link, size: 16),
          label: Text('ai.get_key'.tr()),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ai.hint_${aProvider.name}'.tr(), style: const TextStyle(color: inkSecondary, fontSize: 13)),
            const SizedBox(height: 12),
            if (isEditing) _buildKeyInput(aProvider, aKey) else _buildModelPicker(aProvider, aKey),
          ],
        ),
      ),
    ]);
  }

  Widget _buildKeyInput(AiProvider aProvider, AiKey? aKey)
  {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: TextField(
            controller: _keyCtrls[aProvider],
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            inputFormatters: [LengthLimitingTextInputFormatter(512)],
            onSubmitted: (_) => _saveKey(aProvider),
            decoration: InputDecoration(
              labelText: 'ai.api_key'.tr(),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        FilledButton(
          onPressed: _isBusy ? null : () => _saveKey(aProvider),
          child: Text('ai.check_save'.tr()),
        ),
        if (aKey != null)
          TextButton(
            onPressed: () => setState(() => _replacing.remove(aProvider)),
            child: Text('common.cancel'.tr()),
          ),
      ],
    );
  }

  Widget _buildModelPicker(AiProvider aProvider, AiKey aKey)
  {
    final loaded = _models[aProvider];
    final models = loaded == null || !loaded.any((aModel) => aModel.id == aKey.model)
        ? [AiModel(id: aKey.model, name: aKey.model), ...?loaded]
        : loaded;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DropdownButtonFormField<String>(
            key: ValueKey('${aProvider.name}-${aKey.model}-${models.length}'),
            initialValue: aKey.model,
            isExpanded: true,
            decoration: InputDecoration(labelText: 'ai.model'.tr(), border: const OutlineInputBorder(), isDense: true),
            items: [
              for (final model in models)
                DropdownMenuItem(
                  value: model.id,
                  child: Text(model.name == model.id ? model.id : '${model.name} · ${model.id}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _isBusy ? null : (aModel) => aModel == aKey.model ? null : _setModel(aProvider, aModel),
          ),
        ),
        IconButton(
          tooltip: 'ai.load_models'.tr(),
          onPressed: _isBusy ? null : () => _loadModels(aProvider),
          icon: const Icon(AppIcons.refreshCw, size: 18),
        ),
        TextButton(
          onPressed: _isBusy ? null : () => setState(() => _replacing.add(aProvider)),
          child: Text('ai.replace_key'.tr()),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
          onPressed: _isBusy ? null : () => _deleteKey(aProvider),
          child: Text('ai.delete_key'.tr()),
        ),
      ],
    );
  }

  Widget _buildLimitsCard(AiSettings aSettings)
  {
    final usage = aSettings.currentUsage;
    final numbers = NumberFormat.decimalPattern(context.locale.toLanguageTag());
    final isEnabled = aSettings.source != AiSource.off;

    Widget limitField(TextEditingController aCtrl, String aLabel, int aMax) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: TextField(
            controller: aCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter('$aMax'.length)],
            decoration: InputDecoration(labelText: aLabel, border: const OutlineInputBorder(), isDense: true),
          ),
        );

    return _card([
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ai.limits_title'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('ai.limits_hint'.tr(), style: const TextStyle(color: inkSecondary, fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                limitField(_dailyCtrl, 'ai.daily_limit'.tr(args: [numbers.format(_maxDailyLimit)]), _maxDailyLimit),
                limitField(_monthlyCtrl, 'ai.monthly_limit'.tr(args: [numbers.format(_maxMonthlyLimit)]), _maxMonthlyLimit),
                FilledButton(onPressed: _isBusy ? null : _saveLimits, child: Text('common.save'.tr())),
              ],
            ),
            if (isEnabled) ...[
              const SizedBox(height: 12),
              Text('ai.usage'.tr(args: [
                numbers.format(usage.todayCount),
                numbers.format(aSettings.effectiveDailyLimit),
                numbers.format(usage.monthCount),
                numbers.format(aSettings.effectiveMonthlyLimit),
              ])),
              const SizedBox(height: 4),
              Text(
                'ai.tokens'.tr(args: [numbers.format(usage.monthInputTokens), numbers.format(usage.monthOutputTokens)]),
                style: const TextStyle(color: inkSecondary, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    ]);
  }
}
