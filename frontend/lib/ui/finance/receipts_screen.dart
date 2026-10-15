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

class ReceiptsScreen extends ConsumerStatefulWidget
{
  const ReceiptsScreen({super.key});

  @override
  ConsumerState<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends ConsumerState<ReceiptsScreen>
{
  String _query = '';

  bool _matches(ReceiptListItem aReceipt) =>
      _query.isEmpty ||
      (aReceipt.merchantName ?? '').toLowerCase().contains(_query) ||
      (aReceipt.placeName ?? '').toLowerCase().contains(_query) ||
      (aReceipt.ownerName ?? '').toLowerCase().contains(_query);

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final receiptsAsync = ref.watch(receiptsProv);

    return ListPage(
      title: 'finance.receipts'.tr(),
      onAdd: () => aContext.push('/app/receipts/new'),
      addTooltip: 'finance.new_receipt'.tr(),
      onSearch: (aQuery) => setState(() => _query = aQuery.trim().toLowerCase()),
      child: receiptsAsync.when(
        data: (aReceipts)
        {
          final shown = aReceipts.where(_matches).toList();
          return ListView(
            key: const PageStorageKey('list.receipts'),
            padding: screenPadding(aContext),
            children: [
              Text('finance.receipts_hint'.tr(), style: TextStyle(color: aContext.palette.inkSecondary)),
              const SizedBox(height: 16),
              if (shown.isEmpty)
                Text('finance.no_receipts'.tr(), style: TextStyle(color: aContext.palette.inkMuted))
              else
                ...shown.map((aReceipt) => _ReceiptTile(receipt: aReceipt)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(receiptsProv)),
      ),
    );
  }
}

class _ReceiptTile extends StatelessWidget
{
  final ReceiptListItem receipt;

  const _ReceiptTile({required this.receipt});

  @override
  Widget build(BuildContext aContext)
  {
    final subtitle = [
      formatDateTime(aContext, receipt.receiptTs),
      if (receipt.ownerName != null) receipt.ownerName!,
      if (receipt.placeName != null) receipt.placeName!,
      'finance.items_count'.tr(namedArgs: {'count': '${receipt.itemCount}'}),
      if (receipt.txCount > 0) 'finance.tx_count'.tr(namedArgs: {'count': '${receipt.txCount}'}),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: aContext.palette.border),
      ),
      child: ListTile(
        onTap: () => aContext.push('/app/receipts/${receipt.id}'),
        leading: CircleAvatar(
          backgroundColor: aContext.palette.surfaceMuted,
          child: Icon(AppIcons.receipt, size: 18, color: aContext.palette.inkSecondary),
        ),
        title: Text(receipt.merchantName ?? 'finance.receipt_untitled'.tr()),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Text(
          formatMoney(aContext, receipt.itemsTotal - receipt.discount, receipt.currCode),
          style: TextStyle(fontWeight: FontWeight.w600, color: aContext.palette.inkPrimary),
        ),
      ),
    );
  }
}
