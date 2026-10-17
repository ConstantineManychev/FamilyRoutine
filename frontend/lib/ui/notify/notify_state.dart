import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';

final StateProvider<int> noticeRevisionProv = StateProvider<int>((aRef) => 0);

final FutureProvider<NoticeInbox> noticeInboxProv = FutureProvider<NoticeInbox>((aRef)
{
  aRef.watch(noticeRevisionProv);
  final userId = aRef.watch(authProv.select((aState) => aState.user?.id));
  if (userId == null)
  {
    return const NoticeInbox();
  }
  return aRef.read(apiProv).getNotices();
});

void refreshNotices(WidgetRef aRef) => aRef.read(noticeRevisionProv.notifier).state++;
