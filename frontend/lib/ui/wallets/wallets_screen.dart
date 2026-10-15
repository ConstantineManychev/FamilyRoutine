import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/money.dart';
import '../common/app_theme.dart';

class WalletsScreen extends ConsumerStatefulWidget
{
  const WalletsScreen({super.key});

  @override
  ConsumerState<WalletsScreen> createState() => _WalletsScreenState();
}

class _WalletsScreenState extends ConsumerState<WalletsScreen>
{
  bool _isArchivedVisible = false;
  String _query = '';

  Future<void> _toggleArchive(AccountDto aWallet) async
  {
    try
    {
      await ref.read(apiProv).archiveWallet(aWallet.id, !aWallet.isActive);
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    ref.invalidate(walletsProv);
  }

  Future<void> _handleDelete(AccountDto aWallet) async
  {
    final isWarned = await confirmAction(
      context,
      aTitle: 'wallet.delete'.tr(),
      aMessage: 'wallet.delete_warning'.tr(),
    );

    if (!isWarned || !mounted)
    {
      return;
    }

    final targetWord = 'wallet.delete_word'.tr();
    final isConfirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteCaptchaDialog(targetWord: targetWord),
    );

    if (isConfirmed != true || !mounted)
    {
      return;
    }

    try
    {
      await ref.read(apiProv).deleteWallet(aWallet.id);
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    ref.invalidate(walletsProv);
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final walletsAsync = ref.watch(walletsProv);

    return ListPage(
      title: 'wallet.title'.tr(),
      onAdd: () => aContext.push('/app/wallets/new'),
      addTooltip: 'wallet.add'.tr(),
      onSearch: (aQuery) => setState(() => _query = aQuery.trim().toLowerCase()),
      child: walletsAsync.when(
        data: (aWallets) => _buildList(aContext, aWallets.where(_matches).toList()),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(walletsProv)),
      ),
    );
  }

  bool _matches(AccountDto aWallet) =>
      _query.isEmpty ||
      aWallet.name.toLowerCase().contains(_query) ||
      (aWallet.mask ?? '').contains(_query) ||
      (aWallet.ownerName ?? '').toLowerCase().contains(_query);

  Widget _buildList(BuildContext aContext, List<AccountDto> aWallets)
  {
    final active = aWallets.where((aWallet) => aWallet.isActive).toList();
    final archived = aWallets.where((aWallet) => !aWallet.isActive).toList();

    Widget tile(AccountDto aWallet) => _WalletTile(
          wallet: aWallet,
          onOpen: () => aContext.push('/app/wallets/${aWallet.id}'),
          onToggleArchive: () => _toggleArchive(aWallet),
          onDelete: () => _handleDelete(aWallet),
        );

    return ListView(
      key: const PageStorageKey('list.wallets'),
      padding: screenPadding(aContext),
      children: [
        if (aWallets.isEmpty) BlockEmpty('wallet.empty'.tr()),
        ...active.map(tile),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _isArchivedVisible = !_isArchivedVisible),
              child: Text(_isArchivedVisible ? 'wallet.hide_archived'.tr() : 'wallet.show_archived'.tr()),
            ),
          ),
          if (_isArchivedVisible) ...archived.map(tile),
        ],
      ],
    );
  }
}

class _DeleteCaptchaDialog extends StatefulWidget
{
  final String targetWord;

  const _DeleteCaptchaDialog({required this.targetWord});

  @override
  State<_DeleteCaptchaDialog> createState() => _DeleteCaptchaDialogState();
}

class _DeleteCaptchaDialogState extends State<_DeleteCaptchaDialog>
{
  final _ctrl = TextEditingController();

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    final isMatch = _ctrl.text == widget.targetWord;

    return AlertDialog(
      scrollable: true,
      title: Text('wallet.delete'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('wallet.delete_captcha_desc'.tr(namedArgs: {'word': widget.targetWord})),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.no'.tr())),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: context.palette.danger, foregroundColor: Colors.white),
          onPressed: isMatch ? () => Navigator.of(aContext).pop(true) : null,
          child: Text('wallet.delete'.tr()),
        ),
      ],
    );
  }
}

class _WalletTile extends StatelessWidget
{
  final AccountDto wallet;
  final VoidCallback onOpen;
  final VoidCallback onToggleArchive;
  final VoidCallback onDelete;

  const _WalletTile({
    required this.wallet,
    required this.onOpen,
    required this.onToggleArchive,
    required this.onDelete,
  });

  IconData get _icon => walletIcon(wallet);

  @override
  Widget build(BuildContext aContext)
  {
    final subtitle = walletSubtitle(wallet);

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        onTap: onOpen,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: wallet.isActive ? aContext.colors.primaryContainer : aContext.palette.surfaceMuted,
          child: Icon(_icon, color: wallet.isActive ? aContext.colors.primary : aContext.palette.inkMuted),
        ),
        title: Text(
          wallet.name,
          style: TextStyle(fontWeight: FontWeight.w600, color: wallet.isActive ? aContext.palette.inkPrimary : aContext.palette.inkMuted),
        ),
        subtitle: Text(
          wallet.balance == null ? subtitle : '$subtitle · ${formatMoney(aContext, wallet.balance!, wallet.currCode)}',
        ),
        trailing: wallet.isEditable
            ? PopupMenuButton<String>(
                tooltip: 'common.actions'.tr(),
                onSelected: (aValue)
                {
                  switch (aValue)
                  {
                    case 'edit':
                      onOpen();
                    case 'archive':
                      onToggleArchive();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text('wallet.edit'.tr())),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(wallet.isActive ? 'wallet.archive'.tr() : 'wallet.unarchive'.tr()),
                  ),
                  if (!wallet.isLinked)
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('wallet.delete'.tr(), style: TextStyle(color: aContext.palette.danger)),
                    ),
                ],
              )
            : Icon(AppIcons.eye, color: aContext.palette.inkMuted),
      ),
    );
  }
}

IconData walletIcon(AccountDto aWallet) => switch (aWallet.accountType)
{
  'cash' => AppIcons.banknote,
  'card' => AppIcons.creditCard,
  _ => AppIcons.landmark,
};

String walletSubtitle(AccountDto aWallet) => [
      if (aWallet.mask != null) '•••• ${aWallet.mask}' else 'wallet.type_${aWallet.accountType}'.tr(),
      aWallet.currCode,
      if (!aWallet.isPersonal) 'wallet.shared'.tr(),
      if (aWallet.ownerName != null) 'wallet.owned_by'.tr(args: [aWallet.ownerName!]),
      if (aWallet.isLinked) 'wallet.bank_synced'.tr(),
    ].join(' · ');

class WalletRow extends StatelessWidget
{
  final AccountDto wallet;
  final VoidCallback onTap;

  const WalletRow({super.key, required this.wallet, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    final balance = wallet.balance;

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: aContext.colors.primaryContainer,
        child: Icon(walletIcon(wallet), size: 18, color: aContext.colors.onPrimaryContainer),
      ),
      title: Text(wallet.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(walletSubtitle(wallet), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: balance == null
          ? null
          : Text(
              formatMoney(aContext, balance, wallet.currCode),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: aContext.palette.inkPrimary),
            ),
    );
  }
}
