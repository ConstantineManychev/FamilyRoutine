import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../domain/barcode.dart';
import 'app_icons.dart';
import 'money.dart';

const String _webReaderScript = 'vendor/zxing-wasm/reader.js';
const List<BarcodeFormat> _productFormats = [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA];
const Duration _absenceGap = Duration(milliseconds: 1500);

typedef BarcodeHandler = Future<String?> Function(String aCode);

void configureBarcodeScanner()
{
  if (kIsWeb)
  {
    MobileScannerPlatform.instance.setBarcodeLibraryScriptUrl(_webReaderScript);
  }
}

Future<String?> scanBarcode(BuildContext aContext)
{
  return Navigator.of(aContext, rootNavigator: true).push<String>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => const BarcodeScannerScreen(),
  ));
}

Future<void> scanBarcodes(BuildContext aContext, BarcodeHandler aOnCode)
{
  return Navigator.of(aContext, rootNavigator: true).push<void>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => BarcodeScannerScreen(onCode: aOnCode),
  ));
}

class BarcodeScannerScreen extends StatefulWidget
{
  final BarcodeHandler? onCode;

  const BarcodeScannerScreen({super.key, this.onCode});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen>
{
  final _controller = MobileScannerController(formats: _productFormats, detectionSpeed: DetectionSpeed.normal);
  final _manualCtrl = TextEditingController();
  String? _lastCode;
  DateTime _lastSeenTs = DateTime.fromMillisecondsSinceEpoch(0);
  String? _message;
  bool _isBusy = false;

  bool get _isContinuous => widget.onCode != null;

  @override
  void dispose()
  {
    unawaited(_controller.dispose());
    _manualCtrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture aCapture)
  {
    for (final barcode in aCapture.barcodes)
    {
      final code = normalizeBarcode(barcode.rawValue ?? '');
      if (isValidGtin(code))
      {
        _onCodeSeen(code);
        return;
      }
    }
  }

  void _onCodeSeen(String aCode)
  {
    final now = DateTime.now();
    final isStillInView = aCode == _lastCode && now.difference(_lastSeenTs) < _absenceGap;
    _lastCode = aCode;
    _lastSeenTs = now;
    if (!isStillInView)
    {
      _accept(aCode);
    }
  }

  Future<void> _accept(String aCode) async
  {
    if (_isBusy)
    {
      return;
    }

    final onCode = widget.onCode;
    if (onCode == null)
    {
      Navigator.of(context).pop(aCode);
      return;
    }

    HapticFeedback.selectionClick();
    setState(() => _isBusy = true);
    try
    {
      final message = await onCode(aCode);
      if (mounted)
      {
        setState(() => _message = message);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  void _submitManual()
  {
    final code = normalizeBarcode(_manualCtrl.text);
    if (!isValidGtin(code))
    {
      setState(() => _message = 'items.barcode_invalid'.tr());
      return;
    }
    _manualCtrl.clear();
    _accept(code);
  }

  Widget _buildError(BuildContext aContext, MobileScannerException aError)
  {
    final key = switch (aError.errorCode)
    {
      MobileScannerErrorCode.permissionDenied => 'scanner.err_permission',
      MobileScannerErrorCode.unsupported => 'scanner.err_unsupported',
      _ => 'scanner.err_camera',
    };

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(AppIcons.alertCircle, color: Colors.white, size: 32),
              const SizedBox(height: 12),
              Text(key.tr(), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_isContinuous ? 'scanner.title_many'.tr() : 'scanner.title'.tr()),
        actions: [
          IconButton(
            tooltip: 'scanner.torch'.tr(),
            icon: const Icon(AppIcons.zap),
            onPressed: () => _controller.toggleTorch(),
          ),
          if (_isContinuous)
            TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('scanner.done'.tr())),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(controller: _controller, onDetect: _onDetect, errorBuilder: _buildError),
                IgnorePointer(
                  child: Center(
                    child: FractionallySizedBox(
                      widthFactor: 0.8,
                      child: AspectRatio(
                        aspectRatio: 2.2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_isBusy) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
          Material(
            color: Theme.of(aContext).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _message ?? 'scanner.hint'.tr(),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _message == null ? inkSecondary : inkPrimary, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _manualCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(14)],
                            onSubmitted: (_) => _submitManual(),
                            decoration: InputDecoration(
                              labelText: 'scanner.manual'.tr(),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: _isBusy ? null : _submitManual, child: Text('common.ok'.tr())),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
