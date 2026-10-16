import 'package:flutter_timezone/flutter_timezone.dart';

const String _utcZone = 'UTC';
const Duration _detectTimeout = Duration(seconds: 2);

String? _detectedZone;

String deviceTimeZone() => _detectedZone ?? _offsetZone(DateTime.now().timeZoneOffset);

String _offsetZone(Duration aOffset)
{
  if (aOffset == Duration.zero || aOffset.inMinutes % Duration.minutesPerHour != 0)
  {
    return _utcZone;
  }
  final hours = aOffset.inHours;
  return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
}

Future<void> detectDeviceTimeZone() async
{
  try
  {
    final identifier = (await FlutterTimezone.getLocalTimezone().timeout(_detectTimeout)).identifier;
    if (identifier.isNotEmpty)
    {
      _detectedZone = identifier;
    }
  }
  catch (_)
  {
    _detectedZone = null;
  }
}
