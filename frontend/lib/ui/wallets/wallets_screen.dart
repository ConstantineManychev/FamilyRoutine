import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class WalletsScreen extends ConsumerStatefulWidget {
  const WalletsScreen({super.key});

  @override
  ConsumerState<WalletsScreen> createState() => _WalletsScreenState();
}

class _WalletsScreenState extends ConsumerState<WalletsScreen> {
  bool _showArchived = false;

  Future<void> _toggleArchive(String id, bool currentStatus) async {
    try {
      await ref.read(apiProv).archiveWallet(id, !currentStatus);
      ref.invalidate(walletsProv); // Обновляем после архивации
    } catch (_) {}
  }

  Future<void> _handleDelete(String id) async {
    final bool? confirmWarning = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('wallet.delete'.tr()),
        content: Text('wallet.delete_warning'.tr()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.no'.tr())),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('common.yes'.tr()),
          ),
        ],
      ),
    );

    if (confirmWarning != true) return;

    final targetWord = 'wallet.delete_word'.tr();
    final bool? confirmCaptcha = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('wallet.delete'.tr()),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('wallet.delete_captcha_desc'.tr(namedArgs: {'word': targetWord})),
                  const SizedBox(height: 16),
                  TextField(
                    controller: ctrl,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.no'.tr())),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                  onPressed: ctrl.text == targetWord ? () => Navigator.pop(ctx, true) : null,
                  child: Text('wallet.delete'.tr()),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmCaptcha != true) return;

    try {
      await ref.read(apiProv).deleteWallet(id);
      ref.invalidate(walletsProv); // Обновляем после удаления
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Подключаем реактивный провайдер
    final walletsAsync = ref.watch(walletsProv);

    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('wallet.title'.tr(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: () => context.go('/app/wallets/new'),
                icon: const Icon(LucideIcons.plus, size: 18),
                label: Text('wallet.add'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Expanded(
            child: walletsAsync.when(
              data: (wallets) {
                final activeWallets = wallets.where((w) => w.isActive).toList();
                final archivedWallets = wallets.where((w) => !w.isActive).toList();
                final hasArchived = archivedWallets.isNotEmpty;

                return ListView(
                  children: [
                    ...activeWallets.map((w) => _WalletTile(
                          wallet: w,
                          onEdit: () => context.go('/app/wallets/${w.id}'),
                          onToggleArchive: () => _toggleArchive(w.id, w.isActive),
                          onDelete: () => _handleDelete(w.id),
                        )),
                    if (hasArchived) ...[
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: () => setState(() => _showArchived = !_showArchived),
                          child: Text(_showArchived ? 'wallet.hide_archived'.tr() : 'wallet.show_archived'.tr()),
                        ),
                      ),
                      if (_showArchived)
                        ...archivedWallets.map((w) => _WalletTile(
                              wallet: w,
                              onEdit: () => context.go('/app/wallets/${w.id}'),
                              onToggleArchive: () => _toggleArchive(w.id, w.isActive),
                              onDelete: () => _handleDelete(w.id),
                            )),
                    ]
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('Error: $err')),
            ),
          ),
        ],
      ),
    );
  }
}

class _WalletTile extends StatelessWidget {
  final AccountDto wallet;
  final VoidCallback onEdit;
  final VoidCallback onToggleArchive;
  final VoidCallback onDelete;

  const _WalletTile({
    required this.wallet,
    required this.onEdit,
    required this.onToggleArchive,
    required this.onDelete,
  });

  IconData _getIcon() {
    switch (wallet.accountType) {
      case 'cash': return LucideIcons.banknote;
      case 'card': return LucideIcons.creditCard;
      default: return LucideIcons.landmark;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        onTap: onEdit,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: wallet.isActive ? Colors.blue.shade50 : Colors.grey.shade200,
          child: Icon(_getIcon(), color: wallet.isActive ? Colors.blue.shade700 : Colors.grey),
        ),
        title: Text(wallet.name, style: TextStyle(fontWeight: FontWeight.w600, color: wallet.isActive ? Colors.black87 : Colors.grey)),
        subtitle: Text(wallet.mask != null ? '**** ${wallet.mask}' : 'wallet.type_${wallet.accountType}'.tr()),
        trailing: PopupMenuButton<String>(
          onSelected: (val) {
            if (val == 'edit') onEdit();
            if (val == 'archive') onToggleArchive();
            if (val == 'delete') onDelete();
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(value: 'edit', child: Text('wallet.edit'.tr())),
            PopupMenuItem(value: 'archive', child: Text(wallet.isActive ? 'wallet.archive'.tr() : 'wallet.unarchive'.tr())),
            PopupMenuItem(value: 'delete', child: Text('wallet.delete'.tr(), style: const TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
  }
}