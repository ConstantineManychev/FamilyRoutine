import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';

const List<String> accountTypes = ['cash', 'card', 'bank_acc'];
const List<String> bankTypes = ['monobank', 'aib', 'other'];

class WalletDetailScreen extends ConsumerStatefulWidget
{
  final String? walletId;

  const WalletDetailScreen({super.key, this.walletId});

  @override
  ConsumerState<WalletDetailScreen> createState() => _WalletDetailScreenState();
}

class _WalletDetailScreenState extends ConsumerState<WalletDetailScreen>
{
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _maskCtrl = TextEditingController();

  AccountDto? _wallet;
  List<CurrencyDto> _currs = const [];
  List<FamDto> _fams = const [];
  Object? _loadError;
  bool _isLoading = true;
  bool _isSaving = false;
  String _accType = 'cash';
  String? _bankType;
  String? _currId;
  String? _familyId;

  bool get _isEdit => widget.walletId != null;
  bool get _isEditable => !_isEdit || (_wallet?.isEditable ?? false);
  bool get _isBankRequired => _accType == 'card' || _accType == 'bank_acc';

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    _maskCtrl.dispose();
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
      final currs = await api.getCurrencies();
      final fams = _isEdit ? const <FamDto>[] : await api.getFams();
      final wallet = _isEdit ? await api.getWallet(widget.walletId!) : null;

      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _currs = currs;
        _fams = fams;
        _wallet = wallet;
        _currId = wallet?.currId ?? (currs.isNotEmpty ? currs.first.id : null);

        if (wallet != null)
        {
          _nameCtrl.text = wallet.name;
          _maskCtrl.text = wallet.mask ?? '';
          _accType = wallet.accountType;
          _bankType = wallet.bankType;
          _familyId = wallet.familyId;
        }
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

  String? _validateMask(String? aValue)
  {
    final value = aValue?.trim() ?? '';
    return value.isEmpty || RegExp(r'^\d{4}$').hasMatch(value) ? null : 'validation.mask'.tr();
  }

  Future<void> _save() async
  {
    if (_isSaving || !(_formKey.currentState?.validate() ?? false) || _currId == null)
    {
      return;
    }

    setState(() => _isSaving = true);

    final mask = _maskCtrl.text.trim();

    try
    {
      final api = ref.read(apiProv);

      if (_isEdit)
      {
        await api.updateWallet(widget.walletId!, {
          'name': _nameCtrl.text.trim(),
          'mask': _isBankRequired && mask.isNotEmpty ? mask : null,
        });
      }
      else
      {
        await api.createWallet({
          'name': _nameCtrl.text.trim(),
          'curr_id': _currId,
          'account_type': _accType,
          'bank_type': _isBankRequired ? _bankType : null,
          'mask': _isBankRequired && mask.isNotEmpty ? mask : null,
          'family_id': _familyId,
        });
      }

      ref.invalidate(walletsProv);

      if (mounted)
      {
        context.go('/app/wallets');
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

    return Form(
      key: _formKey,
      child: ListView(
        padding: screenPadding(aContext),
        children: [
          ScreenHeader(
            title: _isEdit ? 'wallet.edit'.tr() : 'wallet.add'.tr(),
            actions: [
              if (_isEditable)
                ElevatedButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: const Icon(AppIcons.save, size: 18),
                  label: Text('common.save'.tr()),
                ),
            ],
          ),
          if (_isEdit && !_isEditable) ...[
            const SizedBox(height: 12),
            Text('wallet.read_only'.tr(), style: const TextStyle(color: Colors.grey)),
          ],
          const SizedBox(height: 24),
          if (!_isEdit && _fams.isNotEmpty) ...[
            _buildOwnerSel(),
            const SizedBox(height: 24),
          ],
          _buildTypeSel(),
          const SizedBox(height: 24),
          _buildCurrSel(),
          const SizedBox(height: 24),
          TextFormField(
            controller: _nameCtrl,
            enabled: _isEditable,
            inputFormatters: [LengthLimitingTextInputFormatter(100)],
            decoration: InputDecoration(
              labelText: 'wallet.name'.tr(),
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(AppIcons.wallet),
            ),
            validator: (aValue) => (aValue == null || aValue.trim().isEmpty) ? 'validation.required'.tr() : null,
          ),
          if (_isBankRequired) ...[
            const SizedBox(height: 24),
            _buildBankSel(),
            const SizedBox(height: 24),
            TextFormField(
              controller: _maskCtrl,
              enabled: _isEditable,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              decoration: InputDecoration(
                labelText: 'wallet.mask'.tr(),
                helperText: 'wallet.mask_hint'.tr(),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(AppIcons.creditCard),
              ),
              validator: _validateMask,
            ),
          ],
          if (_wallet?.isLinked ?? false) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                const Icon(AppIcons.refreshCw, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(child: Text('wallet.linked_hint'.tr())),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOwnerSel()
  {
    return DropdownButtonFormField<String?>(
      initialValue: _familyId,
      decoration: InputDecoration(labelText: 'wallet.owner'.tr(), border: const OutlineInputBorder()),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text('wallet.owner_personal'.tr())),
        ..._fams.map((aFam) => DropdownMenuItem<String?>(value: aFam.id, child: Text(aFam.name))),
      ],
      onChanged: (aValue) => setState(() => _familyId = aValue),
    );
  }

  Widget _buildTypeSel()
  {
    return DropdownButtonFormField<String>(
      initialValue: _accType,
      decoration: InputDecoration(labelText: 'wallet.type'.tr(), border: const OutlineInputBorder()),
      items: accountTypes
          .map((aType) => DropdownMenuItem(value: aType, child: Text('wallet.type_$aType'.tr())))
          .toList(),
      onChanged: _isEdit
          ? null
          : (aValue)
          {
            if (aValue == null)
            {
              return;
            }
            setState(()
            {
              _accType = aValue;
              _bankType = _isBankRequired ? (_bankType ?? bankTypes.first) : null;
            });
          },
    );
  }

  Widget _buildBankSel()
  {
    return DropdownButtonFormField<String>(
      key: ValueKey('bank-$_accType'),
      initialValue: _bankType,
      decoration: InputDecoration(labelText: 'wallet.bank'.tr(), border: const OutlineInputBorder()),
      items: bankTypes.map((aBank) => DropdownMenuItem(value: aBank, child: Text('wallet.bank_$aBank'.tr()))).toList(),
      onChanged: _isEdit ? null : (aValue) => setState(() => _bankType = aValue),
    );
  }

  Widget _buildCurrSel()
  {
    return DropdownButtonFormField<String>(
      initialValue: _currId,
      decoration: InputDecoration(labelText: 'wallet.currency'.tr(), border: const OutlineInputBorder()),
      items: _currs.map((aCurr) => DropdownMenuItem(value: aCurr.id, child: Text(aCurr.code))).toList(),
      onChanged: _isEdit ? null : (aValue) => setState(() => _currId = aValue),
    );
  }
}
