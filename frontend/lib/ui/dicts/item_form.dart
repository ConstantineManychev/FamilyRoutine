import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../domain/barcode.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/ai_photo.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/barcode_scanner.dart';
import '../common/feedback.dart';

const int maxItemNameLen = 200;
const double _labelMaxSide = 1600;
const int _labelQuality = 80;
const int _maxLabelBytes = 2 * 1024 * 1024;
const double _maxKcal = 1000;
const double _maxGrams = 100;
const double _maxPieceG = 10000;

IconData itemKindIcon(ItemKind aKind)
{
  return switch (aKind)
  {
    ItemKind.product => AppIcons.package,
    ItemKind.service => AppIcons.wrench,
    ItemKind.food => AppIcons.apple,
  };
}

String itemKindLabel(ItemKind aKind) => 'items.kind_${aKind.name}'.tr();

String itemUnitLabel(ItemUnit aUnit) => 'items.unit_${aUnit.wire}'.tr();

String itemUnitShort(ItemUnit aUnit) => 'items.unit_short_${aUnit.wire}'.tr();

String itemOwnerLabel(DictItemDto aItem)
{
  return switch (aItem.ownerKind)
  {
    ItemOwnerKind.me => 'items.owner_me'.tr(),
    ItemOwnerKind.catalog => 'items.owner_catalog'.tr(),
    ItemOwnerKind.member => aItem.ownerName ?? 'items.owner_user'.tr(),
    ItemOwnerKind.user => 'items.owner_user'.tr(),
  };
}

IconData itemOwnerIcon(ItemOwnerKind aKind)
{
  return switch (aKind)
  {
    ItemOwnerKind.me => AppIcons.user,
    ItemOwnerKind.catalog => AppIcons.library,
    ItemOwnerKind.member => AppIcons.users,
    ItemOwnerKind.user => AppIcons.globe,
  };
}

String formatNutrient(double aValue) =>
    aValue == aValue.roundToDouble() ? aValue.toStringAsFixed(0) : aValue.toStringAsFixed(1);

String? nutritionSummary(NutritionData aNutrition)
{
  if (aNutrition.isEmpty)
  {
    return null;
  }
  String part(double? aValue) => aValue == null ? '—' : formatNutrient(aValue);
  return 'items.nutrition_short'.tr(args: [
    part(aNutrition.kcal),
    part(aNutrition.prot),
    part(aNutrition.fat),
    part(aNutrition.carb),
  ]);
}

bool isBarcodeAcceptable(String aValue) => aValue.trim().isEmpty || isValidGtin(aValue);

class ItemDraft extends ChangeNotifier
{
  final nameCtrl = TextEditingController();
  final barcodeCtrl = TextEditingController();
  final kcalCtrl = TextEditingController();
  final protCtrl = TextEditingController();
  final fatCtrl = TextEditingController();
  final carbCtrl = TextEditingController();
  final pieceCtrl = TextEditingController();
  ItemKind kind = ItemKind.product;
  ItemUnit unit = ItemUnit.piece;

  ItemDraft({String aName = '', String? aBarcode})
  {
    nameCtrl.text = aName;
    barcodeCtrl.text = aBarcode ?? '';
  }

  String get name => nameCtrl.text.trim();

  String get barcode => normalizeBarcode(barcodeCtrl.text);

  set itemKind(ItemKind aKind)
  {
    kind = aKind;
    notifyListeners();
  }

  set itemUnit(ItemUnit aUnit)
  {
    unit = aUnit;
    notifyListeners();
  }

  void load(DictItemDto aItem)
  {
    nameCtrl.text = aItem.name;
    barcodeCtrl.text = aItem.barcode ?? '';
    kind = aItem.kind;
    unit = aItem.unit;
    _fillNutrition(aItem.nutrition, aIsOverwrite: true);
    notifyListeners();
  }

  NutritionData get nutrition => NutritionData(
        kcal: _parse(kcalCtrl),
        prot: _parse(protCtrl),
        fat: _parse(fatCtrl),
        carb: _parse(carbCtrl),
        pieceG: _parse(pieceCtrl),
      );

  bool get isNutritionValid
  {
    bool isValid(TextEditingController aCtrl, double aMax)
    {
      final text = aCtrl.text.trim();
      if (text.isEmpty)
      {
        return true;
      }
      final value = _parse(aCtrl);
      return value != null && value >= 0 && value <= aMax;
    }

    final piece = _parse(pieceCtrl);
    final isPieceValid = pieceCtrl.text.trim().isEmpty || (piece != null && piece > 0 && piece <= _maxPieceG);
    return isValid(kcalCtrl, _maxKcal) && isValid(protCtrl, _maxGrams) && isValid(fatCtrl, _maxGrams) && isValid(carbCtrl, _maxGrams) && isPieceValid;
  }

  String? validate()
  {
    if (name.isEmpty)
    {
      return 'items.err_name'.tr();
    }
    if (!isBarcodeAcceptable(barcodeCtrl.text))
    {
      return 'items.barcode_invalid'.tr();
    }
    if (!isNutritionValid)
    {
      return 'items.nutrition_invalid'.tr();
    }
    return null;
  }

  Map<String, dynamic> payload() => DictItemDto.payload(
        name,
        kind,
        unit,
        aBarcode: barcode,
        aNutrition: kind == ItemKind.food ? nutrition : NutritionData.empty,
      );

  void applyProduct(ProductInfo aInfo, {bool aIsIdentityLocked = false})
  {
    if (!aIsIdentityLocked)
    {
      final suggested = aInfo.bestName;
      if (suggested != null)
      {
        nameCtrl.text = suggested;
      }
      if (aInfo.barcode != null && barcode.isEmpty)
      {
        barcodeCtrl.text = aInfo.barcode!;
      }
      final infoKind = aInfo.kind ?? (aInfo.nutrition.isEmpty ? null : ItemKind.food);
      if (infoKind != null)
      {
        kind = infoKind;
      }
    }
    _fillNutrition(aInfo.nutrition, aIsOverwrite: false);
    notifyListeners();
  }

  void _fillNutrition(NutritionData aNutrition, {required bool aIsOverwrite})
  {
    void fill(TextEditingController aCtrl, double? aValue)
    {
      if (aValue != null)
      {
        aCtrl.text = formatNutrient(aValue);
      }
      else if (aIsOverwrite)
      {
        aCtrl.clear();
      }
    }

    fill(kcalCtrl, aNutrition.kcal);
    fill(protCtrl, aNutrition.prot);
    fill(fatCtrl, aNutrition.fat);
    fill(carbCtrl, aNutrition.carb);
    fill(pieceCtrl, aNutrition.pieceG);
  }

  static double? _parse(TextEditingController aCtrl)
  {
    final text = aCtrl.text.trim().replaceAll(',', '.');
    return text.isEmpty ? null : double.tryParse(text);
  }

  @override
  void dispose()
  {
    for (final ctrl in [nameCtrl, barcodeCtrl, kcalCtrl, protCtrl, fatCtrl, carbCtrl, pieceCtrl])
    {
      ctrl.dispose();
    }
    super.dispose();
  }
}

Future<DictItemDto?> findDuplicateItem(WidgetRef aRef, Object aError, ItemDraft aDraft) async
{
  final code = ApiException.from(aError).code;
  final api = aRef.read(apiProv);
  if (code == 'BARCODE_TAKEN' && aDraft.barcode.isNotEmpty)
  {
    return (await api.getItems(aBarcode: aDraft.barcode, aLimit: 1)).firstOrNull;
  }
  if (code == 'ITEM_EXISTS')
  {
    final found = await api.getItems(aQuery: aDraft.name, aLimit: 20);
    final name = aDraft.name.toLowerCase();
    return found.where((aItem) => aItem.name.toLowerCase() == name).firstOrNull;
  }
  return null;
}

Future<bool> confirmUseExisting(BuildContext aContext, DictItemDto aItem)
{
  return confirmAction(
    aContext,
    aTitle: 'items.exists_title'.tr(),
    aMessage: 'items.exists_use'.tr(args: [aItem.name]),
    aIsDestructive: false,
  );
}

class ItemFormFields extends ConsumerStatefulWidget
{
  final ItemDraft draft;
  final bool isIdentityEnabled;
  final bool isNutritionEnabled;
  final bool isNameFocused;
  final bool isAutoLookup;
  final String? currentItemId;

  const ItemFormFields({
    super.key,
    required this.draft,
    this.isIdentityEnabled = true,
    this.isNutritionEnabled = true,
    this.isNameFocused = false,
    this.isAutoLookup = false,
    this.currentItemId,
  });

  @override
  ConsumerState<ItemFormFields> createState() => _ItemFormFieldsState();
}

class _ItemFormFieldsState extends ConsumerState<ItemFormFields>
{
  bool _isBusy = false;

  ItemDraft get _draft => widget.draft;

  @override
  void initState()
  {
    super.initState();
    if (widget.isAutoLookup && _draft.name.isEmpty && isValidGtin(_draft.barcode))
    {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookup(aIsQuiet: true));
    }
  }

  Future<void> _busy(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _lookup({bool aIsQuiet = false}) async
  {
    final code = _draft.barcode;
    if (!isValidGtin(code))
    {
      showInfoSnack(context, 'items.off_need_barcode'.tr());
      return;
    }

    await _busy(() async
    {
      ProductLookup result;
      try
      {
        result = await ref.read(apiProv).lookupProduct(code, context.locale.languageCode);
      }
      catch (_)
      {
        result = const ProductLookup(status: LookupStatus.unavailable);
      }
      if (!mounted)
      {
        return;
      }

      final product = result.product;
      if (result.status == LookupStatus.found && product != null)
      {
        _draft.applyProduct(product, aIsIdentityLocked: !widget.isIdentityEnabled);
        showInfoSnack(context, 'items.off_found'.tr(args: [product.bestName ?? code]));
      }
      else if (!aIsQuiet || result.status == LookupStatus.unavailable)
      {
        showInfoSnack(
          context,
          result.status == LookupStatus.notFound ? 'items.off_not_found'.tr() : 'items.off_unavailable'.tr(),
        );
      }
    });
  }

  Future<void> _readLabel() async
  {
    final source = await choosePhotoSource(context, 'items.label_take_photo'.tr());
    if (source == null || !mounted)
    {
      return;
    }
    final isAccepted = await confirmAiConsent(
      context,
      ref,
      aPrefKey: 'items.label_consent',
      aTitleKey: 'items.label_title',
      aMessageKey: 'items.label_consent',
    );
    if (!isAccepted || !mounted)
    {
      return;
    }
    final photo = await pickAiPhoto(context, source, aMaxSide: _labelMaxSide, aQuality: _labelQuality);
    if (photo == null || !mounted)
    {
      return;
    }
    if (photo.bytes.length > _maxLabelBytes)
    {
      showInfoSnack(context, 'items.label_too_big'.tr());
      return;
    }

    final info = await runWithProgress(
      context,
      'items.label_reading'.tr(),
      () => ref.read(apiProv).recognizeLabel(photo.base64, photo.mediaType),
    );
    if (info != null && mounted)
    {
      _draft.applyProduct(info, aIsIdentityLocked: !widget.isIdentityEnabled);
      showInfoSnack(context, 'items.label_done'.tr());
    }
  }

  Future<void> _scan() async
  {
    final code = await scanBarcode(context);
    if (code == null || !mounted)
    {
      return;
    }

    _draft.barcodeCtrl.text = code;
    try
    {
      final owners = await ref.read(apiProv).getItems(aBarcode: code, aLimit: 1);
      final owner = owners.where((aItem) => aItem.id != widget.currentItemId).firstOrNull;
      if (!mounted)
      {
        return;
      }
      if (owner != null)
      {
        showInfoSnack(context, 'items.barcode_used'.tr(args: [owner.name]));
      }
      else if (_draft.name.isEmpty)
      {
        await _lookup(aIsQuiet: true);
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

  Widget _nutrientField(TextEditingController aCtrl, String aLabelKey)
  {
    return SizedBox(
      width: 140,
      child: TextField(
        controller: aCtrl,
        enabled: widget.isNutritionEnabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
        decoration: InputDecoration(labelText: aLabelKey.tr(), border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    final isAiEnabled = ref.watch(aiFeaturesProv).valueOrNull?.isReceiptRecognition ?? false;
    final isFillEnabled = !_isBusy && (widget.isIdentityEnabled || widget.isNutritionEnabled);

    return ListenableBuilder(
      listenable: _draft,
      builder: (_, __)
      {
        final isFood = _draft.kind == ItemKind.food;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _draft.nameCtrl,
              enabled: widget.isIdentityEnabled,
              autofocus: widget.isNameFocused,
              inputFormatters: [LengthLimitingTextInputFormatter(maxItemNameLen)],
              decoration: InputDecoration(labelText: 'items.name'.tr(), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _draft.barcodeCtrl,
              builder: (_, aValue, __)
              {
                final text = aValue.text.trim();
                final isInvalid = text.isNotEmpty && !isValidGtin(text);
                return TextField(
                  controller: _draft.barcodeCtrl,
                  enabled: widget.isIdentityEnabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(14)],
                  decoration: InputDecoration(
                    labelText: 'items.barcode'.tr(),
                    helperText: 'items.barcode_hint'.tr(),
                    helperMaxLines: 2,
                    errorText: isInvalid ? 'items.barcode_invalid'.tr() : null,
                    prefixIcon: const Icon(AppIcons.scanBarcode, size: 18),
                    suffixIcon: !widget.isIdentityEnabled
                        ? null
                        : IconButton(
                            tooltip: 'scanner.title'.tr(),
                            icon: const Icon(AppIcons.camera, size: 18),
                            onPressed: _isBusy ? null : _scan,
                          ),
                    border: const OutlineInputBorder(),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: isFillEnabled ? () => _lookup() : null,
                  icon: _isBusy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(AppIcons.search, size: 18),
                  label: Text('items.off_fill'.tr()),
                ),
                if (isAiEnabled)
                  TextButton.icon(
                    onPressed: isFillEnabled ? _readLabel : null,
                    icon: const Icon(AppIcons.camera, size: 18),
                    label: Text('items.label_photo'.tr()),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<ItemKind>(
              segments: ItemKind.values
                  .map((aKind) => ButtonSegment(value: aKind, icon: Icon(itemKindIcon(aKind), size: 16), label: Text(itemKindLabel(aKind))))
                  .toList(),
              selected: {_draft.kind},
              showSelectedIcon: false,
              onSelectionChanged: widget.isIdentityEnabled ? (aSelected) => _draft.itemKind = aSelected.first : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<ItemUnit>(
              key: ValueKey(_draft.unit),
              initialValue: _draft.unit,
              decoration: InputDecoration(
                labelText: 'items.unit'.tr(),
                helperText: 'items.unit_hint'.tr(),
                border: const OutlineInputBorder(),
              ),
              items: ItemUnit.values
                  .map((aUnit) => DropdownMenuItem(value: aUnit, child: Text('${itemUnitLabel(aUnit)} (${itemUnitShort(aUnit)})')))
                  .toList(),
              onChanged: widget.isIdentityEnabled ? (aValue) => _draft.itemUnit = aValue ?? _draft.unit : null,
            ),
            if (isFood) ...[
              const SizedBox(height: 20),
              Text('items.nutrition'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: aContext.palette.inkSecondary)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _nutrientField(_draft.kcalCtrl, 'items.kcal'),
                  _nutrientField(_draft.protCtrl, 'items.prot'),
                  _nutrientField(_draft.fatCtrl, 'items.fat'),
                  _nutrientField(_draft.carbCtrl, 'items.carb'),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _nutrientField(_draft.pieceCtrl, 'items.piece_g'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('items.piece_g_hint'.tr(), style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted)),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class ItemCreateDialog extends ConsumerStatefulWidget
{
  final String initialName;
  final String? initialBarcode;
  final ItemKind? initialKind;

  const ItemCreateDialog({super.key, required this.initialName, this.initialBarcode, this.initialKind});

  @override
  ConsumerState<ItemCreateDialog> createState() => _ItemCreateDialogState();
}

class _ItemCreateDialogState extends ConsumerState<ItemCreateDialog>
{
  late final ItemDraft _draft = ItemDraft(aName: widget.initialName.trim(), aBarcode: widget.initialBarcode)
    ..kind = widget.initialKind ?? ItemKind.product;
  bool _isSaving = false;

  @override
  void dispose()
  {
    _draft.dispose();
    super.dispose();
  }

  Future<void> _save() async
  {
    final error = _draft.validate();
    if (error != null)
    {
      showInfoSnack(context, error);
      return;
    }

    setState(() => _isSaving = true);
    try
    {
      final item = await ref.read(apiProv).saveItem(null, _draft.payload());
      if (mounted)
      {
        Navigator.of(context).pop(item);
      }
    }
    catch (aError)
    {
      final existing = await findDuplicateItem(ref, aError, _draft).catchError((_) => null);
      if (!mounted)
      {
        return;
      }
      if (existing != null && await confirmUseExisting(context, existing))
      {
        if (mounted)
        {
          Navigator.of(context).pop(existing);
        }
        return;
      }
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('items.new'.tr()),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ItemFormFields(draft: _draft, isNameFocused: _draft.name.isEmpty, isAutoLookup: true),
              const SizedBox(height: 12),
              Text('items.public_hint'.tr(), style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: _isSaving ? null : _save, child: Text('items.add_to_dict'.tr())),
      ],
    );
  }
}

Future<DictItemDto?> showItemCreateDialog(BuildContext aContext, String aInitialName, {ItemKind? aKind})
{
  final isBarcode = isValidGtin(aInitialName);
  return showDialog<DictItemDto>(
    context: aContext,
    builder: (_) => ItemCreateDialog(
      initialName: isBarcode ? '' : aInitialName,
      initialBarcode: isBarcode ? normalizeBarcode(aInitialName) : null,
      initialKind: aKind,
    ),
  );
}
