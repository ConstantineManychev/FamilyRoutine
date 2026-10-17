import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/push/push_platform.dart';

final Provider<PushPlatform> pushPlatformProv = Provider<PushPlatform>((aRef) => createPushPlatform());
