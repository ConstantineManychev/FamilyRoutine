import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/api_prov.dart';
import '../common/feedback.dart';

class BankCallbackScreen extends ConsumerStatefulWidget
{
  final String? code;
  final String? state;
  final String? error;

  const BankCallbackScreen({super.key, this.code, this.state, this.error});

  @override
  ConsumerState<BankCallbackScreen> createState() => _BankCallbackScreenState();
}

class _BankCallbackScreenState extends ConsumerState<BankCallbackScreen>
{
  Object? _failure;
  bool _isDeclined = false;

  @override
  void initState()
  {
    super.initState();
    _complete();
  }

  Future<void> _complete() async
  {
    final code = widget.code;
    final state = widget.state;

    if (widget.error != null || code == null || state == null)
    {
      setState(() => _isDeclined = true);
      return;
    }

    try
    {
      await ref.read(apiProv).completeBankAuth(code, state);
      ref.invalidate(bankConnsProv);
      ref.invalidate(walletsProv);
      if (mounted)
      {
        showInfoSnack(context, 'bank.connected'.tr());
        context.go('/app/wallets');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _failure = aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    if (!_isDeclined && _failure == null)
    {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('bank.completing'.tr()),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_isDeclined ? 'bank.declined'.tr() : errorText(_failure!), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: () => aContext.go('/app/wallets'), child: Text('wallet.title'.tr())),
        ],
      ),
    );
  }
}
