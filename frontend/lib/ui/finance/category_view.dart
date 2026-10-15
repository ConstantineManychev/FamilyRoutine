import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/money.dart';
import '../common/snap_tab_view.dart';

const double _compactWidth = 600;
const double _donutSize = 200;
const double _ringWidth = 26;
const double _segmentGap = 0.03;

const Map<TxCategory, int> _categorySlots = {
  TxCategory.groceries: 0,
  TxCategory.restaurants: 1,
  TxCategory.transport: 2,
  TxCategory.shopping: 3,
  TxCategory.health: 4,
  TxCategory.utilities: 5,
  TxCategory.entertainment: 6,
  TxCategory.travel: 7,
};

Color categoryColor(AppPalette aPalette, TxCategory? aCategory)
{
  final slot = aCategory == null ? null : _categorySlots[aCategory];
  return slot == null ? aPalette.seriesOther : aPalette.seriesAt(slot);
}

class _Slice
{
  final TxCategory? category;
  final double amount;

  const _Slice(this.category, this.amount);
}

class CategoryView extends StatefulWidget
{
  final CategorySeries series;
  final ValueChanged<TxCategory?> onOpenCategory;

  const CategoryView({super.key, required this.series, required this.onOpenCategory});

  @override
  State<CategoryView> createState() => _CategoryViewState();
}

class _CategoryViewState extends State<CategoryView> with SingleTickerProviderStateMixin
{
  late final TabController _tabs = TabController(length: 2, vsync: this)..addListener(_onTab);
  bool _isIncome = false;
  double _dragDx = 0;

  @override
  void dispose()
  {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  void _onTab()
  {
    if (!_tabs.indexIsChanging && mounted)
    {
      setState(() {});
    }
  }

  void _onSwipeEnd(double aWidth)
  {
    final shift = aWidth <= 0 ? 0.0 : -_dragDx / aWidth;
    _dragDx = 0;
    final target = swipeTarget(aAnchor: _tabs.index, aPage: _tabs.index + shift, aCount: _tabs.length);
    if (target != _tabs.index)
    {
      _tabs.animateTo(target, duration: tabSnapDuration);
    }
  }

  List<_Slice> get _items
  {
    final items = widget.series.items
        .map((aItem) => _Slice(aItem.category, _isIncome ? aItem.income : aItem.expense))
        .where((aItem) => aItem.amount > 0)
        .toList()
      ..sort((aLeft, aRight) => aRight.amount.compareTo(aLeft.amount));
    return items;
  }

  @override
  Widget build(BuildContext aContext)
  {
    final isCompact = MediaQuery.sizeOf(aContext).width < _compactWidth;
    final items = _items;
    final total = items.fold<double>(0, (aSum, aItem) => aSum + aItem.amount);

    final toggle = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: false, label: Text('finance.expense'.tr())),
          ButtonSegment(value: true, label: Text('finance.income'.tr())),
        ],
        selected: {_isIncome},
        onSelectionChanged: (aValue) => setState(() => _isIncome = aValue.first),
      ),
    );

    if (items.isEmpty)
    {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toggle,
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text('finance.no_cashflow'.tr(), style: TextStyle(color: aContext.palette.inkMuted))),
          ),
        ],
      );
    }

    final donut = _Donut(items: items, total: total, currCode: widget.series.currCode, isIncome: _isIncome);
    final list = _CategoryList(items: items, total: total, currCode: widget.series.currCode, onOpen: widget.onOpenCategory);

    if (!isCompact)
    {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toggle,
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.all(12), child: donut),
              Expanded(child: list),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toggle,
        TabBar(
          controller: _tabs,
          tabs: [
            Tab(icon: const Icon(AppIcons.list, size: 18), text: 'finance.view_list'.tr()),
            Tab(icon: const Icon(AppIcons.chartPie, size: 18), text: 'finance.view_donut'.tr()),
          ],
        ),
        LayoutBuilder(
          builder: (_, aConstraints) => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _dragDx = 0,
            onHorizontalDragUpdate: (aDetails) => _dragDx += aDetails.delta.dx,
            onHorizontalDragEnd: (_) => _onSwipeEnd(aConstraints.maxWidth),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: _tabs.index == 0
                  ? list
                  : Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Center(child: donut)),
            ),
          ),
        ),
      ],
    );
  }
}

class _CategoryList extends StatelessWidget
{
  final List<_Slice> items;
  final double total;
  final String currCode;
  final ValueChanged<TxCategory?> onOpen;

  const _CategoryList({required this.items, required this.total, required this.currCode, required this.onOpen});

  @override
  Widget build(BuildContext aContext)
  {
    return Column(
      children: [
        for (final item in items)
          _CategoryRow(item: item, share: total <= 0 ? 0 : item.amount / total, currCode: currCode, onTap: () => onOpen(item.category)),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget
{
  final _Slice item;
  final double share;
  final String currCode;
  final VoidCallback onTap;

  const _CategoryRow({required this.item, required this.share, required this.currCode, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final color = categoryColor(palette, item.category);
    final percent = NumberFormat.percentPattern(Localizations.localeOf(aContext).toLanguageTag()).format(share);

    return Semantics(
      button: true,
      container: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.18),
                child: Icon(categoryIcon(item.category), size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            categoryLabel(item.category),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkPrimary),
                          ),
                        ),
                        Text(
                          formatMoney(aContext, item.amount, currCode),
                          style: TextStyle(fontWeight: FontWeight.w700, color: palette.inkPrimary, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ExcludeSemantics(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(value: share, minHeight: 4, color: color, backgroundColor: palette.surfaceMuted),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 44,
                          child: Text(percent, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Donut extends StatelessWidget
{
  final List<_Slice> items;
  final double total;
  final String currCode;
  final bool isIncome;

  const _Donut({required this.items, required this.total, required this.currCode, required this.isIncome});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final grouped = <int, double>{};
    for (final item in items)
    {
      final slot = item.category == null ? null : _categorySlots[item.category];
      grouped.update(slot ?? -1, (aValue) => aValue + item.amount, ifAbsent: () => item.amount);
    }
    final ordered = grouped.keys.toList()..sort((aLeft, aRight) => (aLeft < 0 ? 99 : aLeft).compareTo(aRight < 0 ? 99 : aRight));
    final segments = [for (final slot in ordered) (palette.seriesAt(slot), grouped[slot]!)];

    return SizedBox(
      width: _donutSize,
      height: _donutSize,
      child: CustomPaint(
        painter: _DonutPainter(segments: segments, total: total, surface: palette.surface),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(_ringWidth + 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isIncome ? 'finance.income'.tr() : 'finance.expense'.tr(),
                  style: TextStyle(fontSize: 12, color: palette.inkSecondary),
                ),
                FittedBox(
                  child: Text(
                    formatMoney(aContext, total, currCode),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: palette.inkPrimary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter
{
  final List<(Color, double)> segments;
  final double total;
  final Color surface;

  _DonutPainter({required this.segments, required this.total, required this.surface});

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    if (total <= 0)
    {
      return;
    }
    final rect = Rect.fromCircle(center: aSize.center(Offset.zero), radius: math.min(aSize.width, aSize.height) / 2 - _ringWidth / 2);
    final gap = segments.length > 1 ? _segmentGap : 0.0;
    var start = -math.pi / 2;
    for (final (color, amount) in segments)
    {
      final sweep = amount / total * 2 * math.pi;
      final visible = math.max(0.0, sweep - gap);
      aCanvas.drawArc(
        rect,
        start + gap / 2,
        visible,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _ringWidth,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter aOld) => aOld.segments != segments || aOld.total != total || aOld.surface != surface;
}
