import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/api_prov.dart';
import 'app_icons.dart';
import 'feedback.dart';

class AiPhoto
{
  final Uint8List bytes;
  final String mediaType;

  const AiPhoto({required this.bytes, required this.mediaType});

  String get base64 => base64Encode(bytes);
}

String? imageMediaType(Uint8List aBytes)
{
  bool hasPrefix(List<int> aPrefix, [int aOffset = 0])
  {
    if (aBytes.length < aOffset + aPrefix.length)
    {
      return false;
    }
    for (var index = 0; index < aPrefix.length; index++)
    {
      if (aBytes[aOffset + index] != aPrefix[index])
      {
        return false;
      }
    }
    return true;
  }

  if (hasPrefix([0xFF, 0xD8, 0xFF]))
  {
    return 'image/jpeg';
  }
  if (hasPrefix([0x89, 0x50, 0x4E, 0x47]))
  {
    return 'image/png';
  }
  if (hasPrefix('RIFF'.codeUnits) && hasPrefix('WEBP'.codeUnits, 8))
  {
    return 'image/webp';
  }
  return null;
}

Future<SharedPreferences?> _prefs() async
{
  try
  {
    return await SharedPreferences.getInstance();
  }
  on Exception
  {
    return null;
  }
}

Future<bool> confirmAiConsent(
  BuildContext aContext,
  WidgetRef aRef,
  {
    required String aPrefKey,
    required String aTitleKey,
    required String aMessageKey,
  }
) async
{
  final provider = aRef.read(aiFeaturesProv).valueOrNull?.provider;
  if (provider == null)
  {
    return false;
  }

  final consentPref = '$aPrefKey.${provider.name}';
  final prefs = await _prefs();
  if (prefs?.getBool(consentPref) ?? false)
  {
    return true;
  }
  if (!aContext.mounted)
  {
    return false;
  }

  final isAccepted = await confirmAction(
    aContext,
    aTitle: aTitleKey.tr(),
    aMessage: aMessageKey.tr(args: [provider.company, provider.product]),
    aIsDestructive: false,
  );
  if (isAccepted)
  {
    await prefs?.setBool(consentPref, true);
  }
  return isAccepted;
}

Future<ImageSource?> choosePhotoSource(BuildContext aContext, String aTakePhotoLabel) async
{
  final isPhone = kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  if (!isPhone)
  {
    return ImageSource.gallery;
  }

  return showModalBottomSheet<ImageSource>(
    context: aContext,
    useRootNavigator: true,
    builder: (aSheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(AppIcons.camera),
            title: Text(aTakePhotoLabel),
            onTap: () => Navigator.of(aSheetContext).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(AppIcons.image),
            title: Text('receipt.pick_photo'.tr()),
            onTap: () => Navigator.of(aSheetContext).pop(ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
}

Future<AiPhoto?> pickAiPhoto(
  BuildContext aContext,
  ImageSource aSource,
  {
    required double aMaxSide,
    required int aQuality,
  }
) async
{
  final XFile? photo;
  try
  {
    photo = await ImagePicker().pickImage(
      source: aSource,
      maxWidth: aMaxSide,
      maxHeight: aMaxSide,
      imageQuality: aQuality,
    );
  }
  on PlatformException
  {
    if (aContext.mounted)
    {
      showInfoSnack(aContext, 'scanner.err_permission'.tr());
    }
    return null;
  }
  if (photo == null)
  {
    return null;
  }

  final bytes = await photo.readAsBytes();
  final mediaType = imageMediaType(bytes);
  if (mediaType == null)
  {
    if (aContext.mounted)
    {
      showInfoSnack(aContext, 'receipt.err_image_type'.tr());
    }
    return null;
  }
  return AiPhoto(bytes: bytes, mediaType: mediaType);
}

Future<T?> runWithProgress<T>(BuildContext aContext, String aMessage, Future<T> Function() aAction) async
{
  final navigator = Navigator.of(aContext, rootNavigator: true);
  showDialog<void>(
    context: aContext,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: Text(aMessage)),
          ],
        ),
      ),
    ),
  );

  try
  {
    return await aAction();
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
    return null;
  }
  finally
  {
    navigator.pop();
  }
}
