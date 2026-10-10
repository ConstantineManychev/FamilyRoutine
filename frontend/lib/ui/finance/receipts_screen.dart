import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';

class ReceiptsScreen extends ConsumerWidget
{
  const ReceiptsScreen({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final receiptsAsync = aRef.watch(receiptsProv);

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'finance.receipts'.tr(),
            actions: [
              ElevatedButton.icon(
                onPressed: () => aContext.go('/app/receipts/new'),
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('finance.new_receipt'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('finance.receipts_hint'.tr(), style: const TextStyle(color: inkSecondary)),
          const SizedBox(height: 16),
          Expanded(
            child: receiptsAsync.when(
              data: (aReceipts) => aReceipts.isEmpty
                  ? Center(child: Text('finance.no_receipts'.tr(), style: const TextStyle(color: inkMuted)))
                  : ListView(children: aReceipts.map((aReceipt) => _ReceiptTile(receipt: aReceipt)).toList()),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(receiptsProv)),
            ),
          ),
        ],
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
      if (receipt.placeName != null) receipt.placeName!,
      'finance.items_count'.tr(namedArgs: {'count': '${receipt.itemCount}'}),
      if (receipt.txCount > 0) 'finance.tx_count'.tr(namedArgs: {'count': '${receipt.txCount}'}),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: ListTile(
        onTap: () => aContext.go('/app/receipts/${receipt.id}'),
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFF3F4F6),
          child: Icon(AppIcons.receipt, size: 18, color: inkSecondary),
        ),
        title: Text(receipt.merchantName ?? 'finance.receipt_untitled'.tr()),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Text(
          formatMoney(aContext, receipt.itemsTotal, receipt.currCode),
          style: const TextStyle(fontWeight: FontWeight.w600, color: inkPrimary),
        ),
      ),
    );
  }
}
