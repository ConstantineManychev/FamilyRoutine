import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class WalletDetailScreen extends ConsumerStatefulWidget {
  final String? walletId;
  final VoidCallback onSaved;

  const WalletDetailScreen({super.key, this.walletId, required this.onSaved});

  @override
  ConsumerState<WalletDetailScreen> createState() => _WalletDetailScreenState();
}

class _WalletDetailScreenState extends ConsumerState<WalletDetailScreen> {
  final _nameCtrl = TextEditingController();
  final _maskCtrl = TextEditingController();
  final _apiCtrl = TextEditingController();

  bool _isLoading = true;
  String _accType = 'cash';
  String? _bankType;
  String? _currId;
  List<CurrencyDto> _currs = [];

  bool get _isEdit => widget.walletId != null;
  bool get _reqBank => _accType == 'card' || _accType == 'bank_acc';
  bool get _isMono => _bankType == 'monobank';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      _currs = await ref.read(apiProv).getCurrencies();
      if (_currs.isNotEmpty && _currId == null) _currId = _currs.first.id;

      if (_isEdit) {
        final data = await ref.read(apiProv).getWalletDetail(widget.walletId!);
        _nameCtrl.text = data.name;
        _maskCtrl.text = data.mask ?? '';
        _accType = data.accountType;
        _bankType = data.bankType;
        _currId = data.currId;
        
        if (data.syncCredentials != null && data.syncCredentials!['x_token'] != null) {
          _apiCtrl.text = data.syncCredentials!['x_token'];
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('common.error'.tr())));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _currId == null) return;

    setState(() => _isLoading = true);
    try {
      final payload = {
        'name': name,
        'curr_id': _currId,
        'account_type': _accType,
        'bank_type': _reqBank ? _bankType : null,
        'mask': _reqBank && _maskCtrl.text.isNotEmpty ? _maskCtrl.text.trim() : null,
        'sync_credentials': _isMono && _apiCtrl.text.isNotEmpty ? {'x_token': _apiCtrl.text.trim()} : null,
      };

      if (_isEdit) {
        await ref.read(apiProv).updateWallet(widget.walletId!, payload);
      } else {
        await ref.read(apiProv).createWallet(payload);
      }
      ref.invalidate(walletsProv);
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('common.error'.tr())));
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 32),
            Expanded(
              child: ListView(
                children: [
                  _buildTypeSel(),
                  const SizedBox(height: 24),
                  _buildCurrSel(),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _nameCtrl,
                    decoration: InputDecoration(labelText: 'wallet.name'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(LucideIcons.wallet)),
                  ),
                  if (_reqBank) ...[
                    const SizedBox(height: 24),
                    _buildBankSel(),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _maskCtrl,
                      decoration: InputDecoration(labelText: 'wallet.mask'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(LucideIcons.creditCard)),
                    ),
                  ],
                  if (_isMono) ...[
                    const SizedBox(height: 24),
                    TextField(
                      controller: _apiCtrl,
                      decoration: InputDecoration(labelText: 'wallet.api_key'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(LucideIcons.key)),
                    ),
                  ]
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          _isEdit ? 'wallet.edit'.tr() : 'wallet.add'.tr(),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        ElevatedButton.icon(
          onPressed: _save,
          icon: const Icon(LucideIcons.save, size: 18),
          label: Text('common.save'.tr()),
        )
      ],
    );
  }

  Widget _buildTypeSel() {
    return DropdownButtonFormField<String>(
      value: _accType,
      decoration: InputDecoration(labelText: 'wallet.type'.tr(), border: const OutlineInputBorder()),
      items: ['cash', 'card', 'bank_acc'].map((t) => DropdownMenuItem(value: t, child: Text('wallet.type_$t'.tr()))).toList(),
      onChanged: (val) {
        if (val == null) return;
        setState(() {
          _accType = val;
          if (!_reqBank) {
            _bankType = null;
          } else if (_bankType == null) {
            _bankType = 'monobank';
          }
        });
      },
    );
  }

  Widget _buildBankSel() {
    return DropdownButtonFormField<String>(
      value: _bankType,
      decoration: InputDecoration(labelText: 'wallet.bank'.tr(), border: const OutlineInputBorder()),
      items: ['monobank', 'aib', 'other'].map((t) => DropdownMenuItem(value: t, child: Text('wallet.bank_$t'.tr()))).toList(),
      onChanged: (val) => setState(() => _bankType = val),
    );
  }

  Widget _buildCurrSel() {
    return DropdownButtonFormField<String>(
      value: _currId,
      decoration: InputDecoration(labelText: 'wallet.currency'.tr(), border: const OutlineInputBorder()),
      items: _currs.map((c) => DropdownMenuItem(value: c.id, child: Text(c.code))).toList(),
      onChanged: (val) => setState(() => _currId = val),
    );
  }
}