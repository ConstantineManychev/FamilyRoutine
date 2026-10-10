import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'bank_conns_section.dart';

class WalletsScreen extends ConsumerStatefulWidget
{
  const WalletsScreen({super.key});

  @override
  ConsumerState<WalletsScreen> createState() => _WalletsScreenState();
}

class _WalletsScreenState extends ConsumerState<WalletsScreen>
{
  bool _isArchivedVisible = false;

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

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'wallet.title'.tr(),
            actions: [
              ElevatedButton.icon(
                onPressed: () => aContext.go('/app/wallets/new'),
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('wallet.add'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: walletsAsync.when(
              data: (aWallets) => _buildList(aContext, aWallets),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(walletsProv)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext aContext, List<AccountDto> aWallets)
  {
    final active = aWallets.where((aWallet) => aWallet.isActive).toList();
    final archived = aWallets.where((aWallet) => !aWallet.isActive).toList();

    Widget tile(AccountDto aWallet) => _WalletTile(
          wallet: aWallet,
          onOpen: () => aContext.go('/app/wallets/${aWallet.id}'),
          onToggleArchive: () => _toggleArchive(aWallet),
          onDelete: () => _handleDelete(aWallet),
        );

    return ListView(
      children: [
        const BankConnsSection(),
        const SizedBox(height: 24),
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
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
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

  IconData get _icon
  {
    switch (wallet.accountType)
    {
      case 'cash':
        return AppIcons.banknote;
      case 'card':
        return AppIcons.creditCard;
      default:
        return AppIcons.landmark;
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final subtitle = [
      if (wallet.mask != null) '•••• ${wallet.mask}' else 'wallet.type_${wallet.accountType}'.tr(),
      wallet.currCode,
      if (!wallet.isPersonal) 'wallet.shared'.tr(),
      if (wallet.isLinked) 'wallet.bank_synced'.tr(),
    ].join(' · ');

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        onTap: onOpen,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: wallet.isActive ? Colors.blue.shade50 : Colors.grey.shade200,
          child: Icon(_icon, color: wallet.isActive ? Colors.blue.shade700 : Colors.grey),
        ),
        title: Text(
          wallet.name,
          style: TextStyle(fontWeight: FontWeight.w600, color: wallet.isActive ? Colors.black87 : Colors.grey),
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
                      child: Text('wallet.delete'.tr(), style: const TextStyle(color: Colors.red)),
                    ),
                ],
              )
            : const Icon(AppIcons.eye, color: Colors.grey),
      ),
    );
  }
}
