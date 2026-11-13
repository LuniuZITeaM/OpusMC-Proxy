import 'dart:io';

import 'package:opus_mc_proxy/services/opus_api.dart';

/// Explicit opt-in online smoke check; never logs in or joins a room.
Future<void> main(List<String> args) async {
  final api = OpusApi(
    args.isEmpty ? 'https://xz.honghemc.cn:8443' : args.single,
  );
  try {
    final rooms = await api.publicRooms();
    stdout.writeln('Public room API OK: ${rooms.length} rooms decoded.');
  } finally {
    api.dispose();
  }
}
