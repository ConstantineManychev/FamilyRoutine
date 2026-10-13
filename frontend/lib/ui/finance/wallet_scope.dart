import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';

const String _ownerPrefix = 'owner:';

class WalletScope
{
  final String? value;

  const WalletScope(this.value);

  factory WalletScope.of({String? aAccountId, String? aOwnerId}) =>
      WalletScope(aAccountId ?? (aOwnerId == null ? null : '$_ownerPrefix$aOwnerId'));

  bool get _isOwner => value?.startsWith(_ownerPrefix) ?? false;

  String? get accountId => _isOwner ? null : value;

  String? get ownerId => _isOwner ? value!.substring(_ownerPrefix.length) : null;

  Map<String, String> get query => {
        if (accountId != null) 'account_id': accountId!,
        if (ownerId != null) 'owner_id': ownerId!,
      };
}

String walletLabel(AccountDto aWallet)
{
  final owner = aWallet.ownerName?.split(' ').first;
  return owner == null ? aWallet.name : '${aWallet.name} · $owner';
}

List<DropdownMenuItem<String?>> walletScopeItems(List<AccountDto> aWallets, String? aMyUserId)
{
  final others = <String, String>{};
  for (final wallet in aWallets)
  {
    final ownerId = wallet.userId;
    if (!wallet.isOwn && ownerId != null && wallet.ownerName != null)
    {
      others[ownerId] = wallet.ownerName!;
    }
  }
  final hasForeign = aWallets.any((aWallet) => !aWallet.isOwn || aWallet.familyId != null);

  return [
    DropdownMenuItem<String?>(value: null, child: Text('finance.all_wallets'.tr())),
    if (hasForeign && aMyUserId != null)
      DropdownMenuItem<String?>(value: '$_ownerPrefix$aMyUserId', child: Text('finance.my_wallets'.tr())),
    for (final entry in others.entries)
      DropdownMenuItem<String?>(
        value: '$_ownerPrefix${entry.key}',
        child: Text('finance.owner_wallets'.tr(args: [entry.value]), overflow: TextOverflow.ellipsis),
      ),
    for (final wallet in aWallets)
      DropdownMenuItem<String?>(value: wallet.id, child: Text(walletLabel(wallet), overflow: TextOverflow.ellipsis)),
  ];
}
