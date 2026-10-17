import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../common/page_frames.dart';
import 'stock_format.dart';

const double _contentMaxWidth = 760;
const List<int?> _periods = [30, 90, null];

class StockHistoryScreen extends ConsumerStatefulWidget
{
  final StockStoreRef store;

  const StockHistoryScreen({super.key, required this.store});

  factory StockHistoryScreen.fromQuery(Map<String, String> aQuery) => StockHistoryScreen(
        store: aQuery['family'] == null ? StockStoreRef.personal : StockStoreRef(familyId: aQuery['family'], familyName: aQuery['name']),
      );

  @override
  ConsumerState<StockHistoryScreen> createState() => _StockHistoryScreenState();
}

class _StockHistoryScreenState extends ConsumerState<StockHistoryScreen>
{
  bool _isWasteOnly = false;
  int? _days = 30;
  StockMoves? _moves;
  Object? _error;
  int _generation = 0;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    final generation = ++_generation;
    final days = _days;
    try
    {
      final moves = await ref.read(apiProv).getStockMoves(
            aStore: widget.store,
            aKind: _isWasteOnly ? StockMoveKind.waste : null,
            aFrom: days == null ? null : DateTime.now().subtract(Duration(days: days)),
          );
      if (mounted && generation == _generation)
      {
        setState(()
        {
          _moves = moves;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted && generation == _generation)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _update(VoidCallback aChange)
  {
    setState(()
    {
      aChange();
      _moves = null;
      _error = null;
    });
    _load();
  }

  String _periodLabel(int? aDays) => aDays == null ? 'stock.period_all'.tr() : 'stock.period_days'.tr(args: ['$aDays']);

  Widget _wasteCard(BuildContext aContext, StockMoves aMoves)
  {
    final palette = aContext.palette;
    final parts = [
      if (aMoves.wasteG > 0) formatStockQty(aContext, aMoves.wasteG, StockMeasure.g),
      if (aMoves.wasteMl > 0) formatStockQty(aContext, aMoves.wasteMl, StockMeasure.ml),
      if (aMoves.wastePcs > 0) formatStockQty(aContext, aMoves.wastePcs, StockMeasure.pcs),
      for (final cost in aMoves.wasteCosts) formatMoney(aContext, cost.amount, cost.currCode),
    ];
    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(AppIcons.trash, color: palette.inkSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('stock.waste_total'.tr(args: [_periodLabel(_days)]), style: TextStyle(color: palette.inkSecondary)),
                  const SizedBox(height: 4),
                  Text(
                    parts.isEmpty ? 'stock.waste_none'.tr() : parts.join(' · '),
                    key: const ValueKey('stock.waste_total'),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moveTile(BuildContext aContext, StockMove aMove)
  {
    final palette = aContext.palette;
    final cost = aMove.cost;
    final currCode = aMove.currCode;
    final reason = aMove.reason;
    final note = aMove.note;
    final actor = aMove.actorName;
    return ListTile(
      key: ValueKey('stock.move.${aMove.id}'),
      leading: Icon(moveIcon(aMove.kind), color: aMove.kind == StockMoveKind.waste ? palette.danger : palette.inkSecondary),
      title: Text(aMove.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          [
            moveKindLabel(aMove.kind),
            formatStockQty(aContext, aMove.qty, aMove.measure),
            if (cost != null && currCode != null) formatMoney(aContext, cost, currCode),
          ].join(' · '),
          [
            DateFormat.MMMd(aContext.locale.toLanguageTag()).add_Hm().format(aMove.createdTs),
            if (reason != null) reasonLabel(reason),
            if (actor != null) actor,
          ].join(' · '),
          if (note != null && note.isNotEmpty) note,
        ].join('\n'),
        style: TextStyle(fontSize: 12, color: palette.inkMuted),
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final moves = _moves;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (moves == null)
    {
      content = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else
    {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _wasteCard(aContext, moves),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            semanticContainer: false,
            clipBehavior: Clip.antiAlias,
            child: moves.moves.isEmpty
                ? BlockEmpty('stock.history_empty'.tr())
                : Column(children: [for (final move in moves.moves) _moveTile(aContext, move)]),
          ),
        ],
      );
    }

    return SubPage(
      title: 'stock.history_title'.tr(args: [storeLabel(widget.store)]),
      child: ListView(
        padding: screenPadding(aContext),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SegmentedButton<bool>(
                        key: const ValueKey('stock.history_kind'),
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(value: false, label: Text('stock.history_all'.tr())),
                          ButtonSegment(value: true, label: Text('stock.history_waste'.tr())),
                        ],
                        selected: {_isWasteOnly},
                        onSelectionChanged: (aValue) => _update(() => _isWasteOnly = aValue.first),
                      ),
                      for (final days in _periods)
                        ChoiceChip(
                          showCheckmark: false,
                          label: Text(_periodLabel(days)),
                          selected: _days == days,
                          onSelected: (_) => _update(() => _days = days),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  content,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
