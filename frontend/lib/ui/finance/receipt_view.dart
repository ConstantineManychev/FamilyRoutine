import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../dicts/item_form.dart';
import 'transactions_screen.dart';

const Color _borderColor = Color(0xFFE5E7EB);
const double _contentMaxWidth = 720;

class ReceiptView extends StatelessWidget
{
  final ReceiptDto receipt;

  const ReceiptView({super.key, required this.receipt});

  String _qty(BuildContext aContext, ReceiptItem aItem) =>
      '${NumberFormat('#,##0.###', aContext.locale.toLanguageTag()).format(aItem.qty)} ${itemUnitShort(aItem.unit)}';

  @override
  Widget build(BuildContext aContext)
  {
    final place = [
      if (receipt.placeName != null) receipt.placeName!,
      if (receipt.branch != null) receipt.branch!,
    ].join(', ');

    return ListView(
      padding: screenPadding(aContext),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenHeader(title: receipt.merchantName ?? 'finance.receipt_untitled'.tr()),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(AppIcons.eye, size: 16, color: inkMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        receipt.ownerName == null
                            ? 'finance.receipt_read_only'.tr()
                            : 'finance.receipt_shared_by'.tr(args: [receipt.ownerName!]),
                        style: const TextStyle(color: inkSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  [formatDateTime(aContext, receipt.receiptTs), if (place.isNotEmpty) place].join(' · '),
                  style: const TextStyle(color: inkSecondary),
                ),
                const SizedBox(height: 16),
                _buildItems(aContext),
                const SizedBox(height: 16),
                _buildTotals(aContext),
                if (receipt.txs.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('finance.payments'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  for (final tx in receipt.txs)
                    TxTile(
                      tx: tx,
                      trailing: Text(
                        formatMoney(aContext, tx.amount, tx.currCode),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
                if (receipt.note != null && receipt.note!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(receipt.note!, style: const TextStyle(color: inkSecondary)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItems(BuildContext aContext)
  {
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: _borderColor)),
      child: Column(
        children: [
          for (final item in receipt.items)
            ListTile(
              dense: true,
              title: Text(item.name),
              subtitle: Text(
                [
                  _qty(aContext, item),
                  if (item.unitPrice != null) formatMoney(aContext, item.unitPrice!, receipt.currCode),
                ].join(' × '),
              ),
              trailing: Text(
                formatMoney(aContext, item.amount, receipt.currCode),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: inkPrimary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTotals(BuildContext aContext)
  {
    Widget line(String aLabel, double aValue, {bool aIsBold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(aLabel, style: const TextStyle(color: inkSecondary))),
              Text(
                formatMoney(aContext, aValue, receipt.currCode),
                style: TextStyle(fontWeight: aIsBold ? FontWeight.bold : FontWeight.w500, color: inkPrimary),
              ),
            ],
          ),
        );

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: _borderColor)),
      child: Column(
        children: [
          line('finance.items_total'.tr(), receipt.itemsTotal),
          if (receipt.discount > 0.004) line('finance.receipt_discount'.tr(), -receipt.discount),
          line('finance.paid_by_tx'.tr(), receipt.paidTotal),
          if (receipt.cashAmount > 0.004) line('finance.cash_rest'.tr(), receipt.cashAmount),
          const Divider(),
          line('finance.payable'.tr(), receipt.itemsTotal - receipt.discount, aIsBold: true),
        ],
      ),
    );
  }
}
