import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'item_form.dart';
import 'items_screen.dart';

const Color _cheapestColor = Color(0xFF15803D);

class ItemDetailScreen extends ConsumerStatefulWidget
{
  final String? itemId;

  const ItemDetailScreen({super.key, this.itemId});

  @override
  ConsumerState<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends ConsumerState<ItemDetailScreen>
{
  final _nameCtrl = TextEditingController();
  ItemKind _kind = ItemKind.product;
  ItemUnit _unit = ItemUnit.piece;
  bool _isCustom = true;
  List<ItemPriceDto> _prices = const [];
  bool _isLoading = false;
  bool _isSaving = false;
  Object? _loadError;

  bool get _isEdit => widget.itemId != null;

  bool get _isEditable => !_isEdit || _isCustom;

  @override
  void initState()
  {
    super.initState();
    if (_isEdit)
    {
      _load();
    }
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    setState(()
    {
      _isLoading = true;
      _loadError = null;
    });

    try
    {
      final api = ref.read(apiProv);
      final item = await api.getItem(widget.itemId!);
      final prices = await api.getItemPrices(widget.itemId!);
      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _nameCtrl.text = item.name;
        _kind = item.kind;
        _unit = item.unit;
        _isCustom = item.isCustom;
        _prices = prices;
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _save() async
  {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty)
    {
      showInfoSnack(context, 'items.err_name'.tr());
      return;
    }

    setState(() => _isSaving = true);

    try
    {
      final saved = await ref.read(apiProv).saveItem(widget.itemId, DictItemDto.payload(name, _kind, _unit));
      ref.invalidate(itemsProv);
      if (!mounted)
      {
        return;
      }

      showInfoSnack(context, 'common.saved'.tr());
      if (!_isEdit)
      {
        context.go('/app/items/${saved.id}');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'items.delete'.tr(),
      aMessage: 'items.delete_confirm'.tr(),
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    try
    {
      await ref.read(apiProv).deleteItem(widget.itemId!);
      ref.invalidate(itemsProv);
      if (mounted)
      {
        context.go('/app/items');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    if (_isLoading)
    {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null)
    {
      return ErrorRetry(error: _loadError!, onRetry: _load);
    }

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'items.item'.tr() : 'items.new'.tr(),
          actions: [
            if (_isEdit && _isCustom)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(AppIcons.trash2, size: 18),
                label: Text('common.delete'.tr()),
              ),
            if (_isEditable)
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(AppIcons.save, size: 18),
                label: Text('common.save'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 24),
        if (!_isEditable) ...[
          Row(
            children: [
              const Icon(AppIcons.lock, size: 18, color: inkMuted),
              const SizedBox(width: 8),
              Expanded(child: Text('items.system_hint'.tr(), style: const TextStyle(color: inkSecondary))),
            ],
          ),
          const SizedBox(height: 16),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ItemFormFields(
            nameCtrl: _nameCtrl,
            kind: _kind,
            unit: _unit,
            isEnabled: _isEditable,
            onKindChanged: (aKind) => setState(() => _kind = aKind),
            onUnitChanged: (aUnit) => setState(() => _unit = aUnit),
          ),
        ),
        if (_isEdit) ...[
          const SizedBox(height: 32),
          Text('items.prices'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('items.prices_hint'.tr(args: [itemUnitShort(_unit)]), style: const TextStyle(color: inkSecondary)),
          const SizedBox(height: 12),
          if (_prices.isEmpty)
            Text('items.no_prices'.tr(), style: const TextStyle(color: inkMuted))
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(children: _buildPriceRows(aContext)),
            ),
        ],
      ],
    );
  }

  List<Widget> _buildPriceRows(BuildContext aContext)
  {
    final cheapestByCurrency = <String, double>{};
    final merchantsByCurrency = <String, int>{};
    for (final price in _prices)
    {
      final current = cheapestByCurrency[price.currCode];
      cheapestByCurrency[price.currCode] = current == null || price.lastPrice < current ? price.lastPrice : current;
      merchantsByCurrency.update(price.currCode, (aCount) => aCount + 1, ifAbsent: () => 1);
    }

    return _prices.map((aPrice)
    {
      final isCheapest = (merchantsByCurrency[aPrice.currCode] ?? 0) > 1 && aPrice.lastPrice == cheapestByCurrency[aPrice.currCode];
      return _PriceRow(price: aPrice, unit: _unit, isCheapest: isCheapest);
    }).toList();
  }
}

class _PriceRow extends StatelessWidget
{
  final ItemPriceDto price;
  final ItemUnit unit;
  final bool isCheapest;

  const _PriceRow({required this.price, required this.unit, required this.isCheapest});

  @override
  Widget build(BuildContext aContext)
  {
    final perUnit = ' / ${itemUnitShort(unit)}';
    final details = [
      '${'items.min'.tr()} ${formatMoney(aContext, price.minPrice, price.currCode)}',
      '${'items.avg'.tr()} ${formatMoney(aContext, price.avgPrice, price.currCode)}',
      'items.purchases'.tr(args: ['${price.purchaseCount}']),
      formatDate(aContext, price.lastTs),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCheapest ? const BorderSide(color: _cheapestColor) : BorderSide.none,
      ),
      child: ListTile(
        leading: const Icon(AppIcons.store, color: inkSecondary),
        title: Text(price.merchantName ?? 'items.no_merchant'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(details),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${formatMoney(aContext, price.lastPrice, price.currCode)}$perUnit',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: inkPrimary),
            ),
            if (isCheapest)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AppIcons.checkCircle, size: 14, color: _cheapestColor),
                  const SizedBox(width: 4),
                  Text('items.cheapest'.tr(), style: const TextStyle(fontSize: 12, color: _cheapestColor)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
