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

const String monobankTokenUrl = 'https://api.monobank.ua/';
const String defaultAspspCountry = 'IE';
const List<String> preferredAspspNames = ['AIB', 'ALLIED IRISH'];

String? preferredAspsp(List<AspspDto> aAspsps)
{
  for (final preferred in preferredAspspNames)
  {
    final match = aAspsps.where((aAspsp) => aAspsp.name.toUpperCase().startsWith(preferred)).firstOrNull;
    if (match != null)
    {
      return match.name;
    }
  }
  return aAspsps.firstOrNull?.name;
}

class BankConnsSection extends ConsumerWidget
{
  const BankConnsSection({super.key});

  Future<void> _sync(BuildContext aContext, WidgetRef aRef, BankConnDto aConn) async
  {
    try
    {
      await aRef.read(apiProv).requestBankSync(aConn.id);
      if (aContext.mounted)
      {
        showInfoSnack(aContext, 'bank.sync_requested'.tr());
      }
      aRef.invalidate(bankConnsProv);
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
    }
  }

  Future<void> _disconnect(BuildContext aContext, WidgetRef aRef, BankConnDto aConn) async
  {
    final isConfirmed = await confirmAction(
      aContext,
      aTitle: 'bank.disconnect'.tr(),
      aMessage: 'bank.disconnect_confirm'.tr(),
    );

    if (!isConfirmed)
    {
      return;
    }

    try
    {
      await aRef.read(apiProv).deleteBankConn(aConn.id);
      aRef.invalidate(bankConnsProv);
      aRef.invalidate(walletsProv);
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    final conns = aRef.watch(bankConnsProv).valueOrNull ?? const <BankConnDto>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('bank.connections'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            OutlinedButton.icon(
              onPressed: () async
              {
                final isConnected = await showDialog<bool>(context: aContext, builder: (_) => const ConnectBankDialog());
                if (isConnected == true)
                {
                  aRef.invalidate(bankConnsProv);
                  aRef.invalidate(walletsProv);
                }
              },
              icon: const Icon(AppIcons.plug, size: 18),
              label: Text('bank.connect'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (conns.isEmpty)
          Text('bank.none'.tr(), style: const TextStyle(color: inkMuted))
        else
          ...conns.map((aConn) => _ConnTile(
                conn: aConn,
                onSync: () => _sync(aContext, aRef, aConn),
                onDisconnect: () => _disconnect(aContext, aRef, aConn),
              )),
      ],
    );
  }
}

class _ConnTile extends StatelessWidget
{
  final BankConnDto conn;
  final VoidCallback onSync;
  final VoidCallback onDisconnect;

  const _ConnTile({required this.conn, required this.onSync, required this.onDisconnect});

  @override
  Widget build(BuildContext aContext)
  {
    final details = [
      'bank.status_${conn.status}'.tr(),
      'bank.accounts'.tr(namedArgs: {'count': '${conn.accountCount}'}),
      if (conn.lastSyncTs != null) '${'bank.last_sync'.tr()}: ${formatDateTime(aContext, conn.lastSyncTs!)}',
      if (conn.validUntil != null) '${'bank.valid_until'.tr()}: ${DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(conn.validUntil!)}',
      if (conn.lastError != null) 'bank.error_${conn.lastError}'.tr(),
    ].join(' · ');

    final statusColor = conn.isActive && conn.lastError == null ? Colors.green.shade700 : Colors.orange.shade800;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFF3F4F6),
          child: Icon(AppIcons.landmark, size: 18, color: statusColor),
        ),
        title: Text(conn.aspspName ?? 'bank.provider_${conn.provider}'.tr()),
        subtitle: Text(details),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conn.isActive)
              IconButton(tooltip: 'bank.sync_now'.tr(), icon: const Icon(AppIcons.refreshCw, size: 18), onPressed: onSync),
            IconButton(tooltip: 'bank.disconnect'.tr(), icon: const Icon(AppIcons.unlink, size: 18), onPressed: onDisconnect),
          ],
        ),
      ),
    );
  }
}

class ConnectBankDialog extends ConsumerStatefulWidget
{
  const ConnectBankDialog({super.key});

  @override
  ConsumerState<ConnectBankDialog> createState() => _ConnectBankDialogState();
}

class _ConnectBankDialogState extends ConsumerState<ConnectBankDialog>
{
  final _tokenCtrl = TextEditingController();
  String _provider = 'monobank';
  bool _isBusy = false;
  List<AspspDto>? _aspsps;
  Object? _aspspError;
  String? _aspspName;

  @override
  void dispose()
  {
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectMonobank() async
  {
    final token = _tokenCtrl.text.trim();
    if (token.length < 16)
    {
      showInfoSnack(context, 'validation.sync_token'.tr());
      return;
    }

    setState(() => _isBusy = true);

    try
    {
      await ref.read(apiProv).connectMonobank(token);
      _tokenCtrl.clear();
      if (mounted)
      {
        showInfoSnack(context, 'bank.connected'.tr());
        Navigator.of(context).pop(true);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isBusy = false);
      }
    }
  }

  void _selectProvider(String aProvider)
  {
    setState(() => _provider = aProvider);
    if (aProvider == 'enable_banking' && _aspsps == null)
    {
      _loadAspsps();
    }
  }

  Future<void> _loadAspsps() async
  {
    setState(() => _aspspError = null);

    try
    {
      final aspsps = await ref.read(apiProv).getAspsps(defaultAspspCountry);
      if (mounted)
      {
        setState(()
        {
          _aspsps = aspsps;
          _aspspName = preferredAspsp(aspsps);
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _aspspError = aError);
      }
    }
  }

  Future<void> _connectEnableBanking() async
  {
    final aspspName = _aspspName;
    if (aspspName == null)
    {
      return;
    }

    setState(() => _isBusy = true);

    try
    {
      final url = await ref.read(apiProv).startBankAuth(aspspName, defaultAspspCountry);
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('bank.connect'.tr()),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'monobank', label: Text('bank.provider_monobank'.tr())),
                ButtonSegment(value: 'enable_banking', label: Text('bank.provider_aib'.tr())),
              ],
              selected: {_provider},
              onSelectionChanged: (aValue) => _selectProvider(aValue.first),
            ),
            const SizedBox(height: 16),
            if (_provider == 'monobank') ...[
              Text('bank.mono_hint'.tr(), style: const TextStyle(color: inkSecondary)),
              TextButton(
                onPressed: () => launchUrl(Uri.parse(monobankTokenUrl)),
                child: const Text(monobankTokenUrl),
              ),
              TextField(
                controller: _tokenCtrl,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                inputFormatters: [LengthLimitingTextInputFormatter(256)],
                decoration: InputDecoration(
                  labelText: 'bank.mono_token'.tr(),
                  helperText: 'bank.token_security'.tr(),
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(AppIcons.key),
                ),
              ),
            ]
            else ...[
              Text('bank.eb_hint'.tr(), style: const TextStyle(color: inkSecondary)),
              const SizedBox(height: 16),
              _buildAspspPicker(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: _isBusy || (_provider != 'monobank' && _aspspName == null)
              ? null
              : (_provider == 'monobank' ? _connectMonobank : _connectEnableBanking),
          child: Text(_provider == 'monobank' ? 'bank.connect'.tr() : 'bank.go_to_bank'.tr()),
        ),
      ],
    );
  }

  Widget _buildAspspPicker()
  {
    final aspsps = _aspsps;
    final error = _aspspError;

    if (error != null)
    {
      return Row(
        children: [
          const Icon(AppIcons.alertCircle, size: 18, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(child: Text(errorText(error), style: TextStyle(color: Colors.red.shade800))),
          TextButton(onPressed: _loadAspsps, child: Text('common.retry'.tr())),
        ],
      );
    }

    if (aspsps == null)
    {
      return const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()));
    }

    if (aspsps.isEmpty)
    {
      return Text('bank.no_aspsps'.tr(), style: TextStyle(color: Colors.red.shade800));
    }

    return DropdownButtonFormField<String>(
      initialValue: _aspspName,
      isExpanded: true,
      decoration: InputDecoration(labelText: 'bank.choose_bank'.tr(), border: const OutlineInputBorder()),
      items: aspsps.map((aAspsp) => DropdownMenuItem(value: aAspsp.name, child: Text(aAspsp.name))).toList(),
      onChanged: (aValue) => setState(() => _aspspName = aValue),
    );
  }
}
