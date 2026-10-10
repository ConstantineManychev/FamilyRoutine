import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/money.dart';

const double _barHeight = 10;
const double _barRadius = 4;

class CategoryBreakdown extends StatefulWidget
{
  final CategorySeries series;
  final ValueChanged<TxCategory?> onOpenCategory;

  const CategoryBreakdown({super.key, required this.series, required this.onOpenCategory});

  @override
  State<CategoryBreakdown> createState() => _CategoryBreakdownState();
}

class _CategoryBreakdownState extends State<CategoryBreakdown>
{
  bool _isIncome = false;

  double _value(CategoryAmount aItem) => _isIncome ? aItem.income : aItem.expense;

  @override
  Widget build(BuildContext aContext)
  {
    final series = widget.series;
    final total = _isIncome ? series.incomeTotal : series.expenseTotal;
    final items = series.items.where((aItem) => _value(aItem) > 0).toList()
      ..sort((aLeft, aRight) => _value(aRight).compareTo(_value(aLeft)));
    final maxValue = items.isEmpty ? 0.0 : _value(items.first);
    final barColor = _isIncome ? incomeColor : expenseColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text('finance.expenses'.tr())),
                ButtonSegment(value: true, label: Text('finance.incomes'.tr())),
              ],
              selected: {_isIncome},
              onSelectionChanged: (aValue) => setState(() => _isIncome = aValue.first),
            ),
            const Spacer(),
            Text(
              '${'finance.total'.tr()}: ${formatMoney(aContext, total, series.currCode)}',
              style: const TextStyle(fontWeight: FontWeight.w600, color: inkPrimary),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          SizedBox(
            height: 80,
            child: Center(child: Text('finance.no_cashflow'.tr(), style: const TextStyle(color: inkMuted))),
          )
        else
          ...items.map((aItem) => _CategoryRow(
                item: aItem,
                value: _value(aItem),
                share: total == 0 ? 0 : _value(aItem) / total,
                fraction: maxValue == 0 ? 0 : _value(aItem) / maxValue,
                currCode: series.currCode,
                barColor: barColor,
                onTap: () => widget.onOpenCategory(aItem.category),
              )),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget
{
  final CategoryAmount item;
  final double value;
  final double share;
  final double fraction;
  final String currCode;
  final Color barColor;
  final VoidCallback onTap;

  const _CategoryRow({
    required this.item,
    required this.value,
    required this.share,
    required this.fraction,
    required this.currCode,
    required this.barColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final percent = NumberFormat.percentPattern(aContext.locale.toLanguageTag()).format(share);

    return Tooltip(
      message: 'finance.category_hint'.tr(args: ['${item.txCount}']),
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              Icon(categoryIcon(item.category), size: 18, color: inkSecondary),
              const SizedBox(width: 10),
              SizedBox(
                width: 150,
                child: Text(categoryLabel(item.category), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, aConstraints) => Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: (aConstraints.maxWidth * fraction).clamp(2.0, aConstraints.maxWidth).toDouble(),
                      height: _barHeight,
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(_barRadius)),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: Text(
                  formatMoney(aContext, value, currCode),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: inkPrimary),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(percent, textAlign: TextAlign.right, style: const TextStyle(color: inkSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
