import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_proxy/services/room_admission.dart';

void main() {
  testWidgets('queue outlives startup timeout, notice resumes deadline', (
    tester,
  ) async {
    var expired = 0;
    final admission = RoomAdmission(onTimeout: () => expired++);
    admission.onMessage('queue');
    await tester.pump(const Duration(minutes: 5));
    expect(expired, 0);
    admission.onMessage('queue');
    admission.onMessage('room');
    await tester.pump(const Duration(minutes: 5));
    expect(expired, 0);
    admission.onMessage('notice');
    await tester.pump(const Duration(seconds: 89));
    expect(expired, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(expired, 1);
    admission.close();
  });

  testWidgets('login and cancellation stop admission deadlines', (
    tester,
  ) async {
    var expired = 0;
    final entered = RoomAdmission(onTimeout: () => expired++);
    entered.onMessage('queue');
    entered.onMessage('login');
    entered.onMessage('notice');
    entered.onMessage('queue');
    final cancelled = RoomAdmission(onTimeout: () => expired++)..close();
    cancelled.onMessage('notice');
    await tester.pump(const Duration(minutes: 5));
    expect(expired, 0);
  });

  testWidgets('silent startup still times out', (tester) async {
    var expired = 0;
    final admission = RoomAdmission(onTimeout: () => expired++);
    admission.onMessage('room');
    admission.onMessage('notice');
    await tester.pump(const Duration(seconds: 90));
    expect(expired, 1);
    admission.close();
  });
}
