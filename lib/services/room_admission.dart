import 'dart:async';

/// A queued room can wait indefinitely, just like the official loading screen.
/// A notice clears that queue and resumes the bounded room startup wait.
class RoomAdmission {
  RoomAdmission({
    required this.onTimeout,
    this.timeout = const Duration(seconds: 90),
  }) {
    _arm();
  }

  final void Function() onTimeout;
  final Duration timeout;
  Timer? _timer;
  bool _queued = false;
  bool _finished = false;

  void _arm() {
    _timer?.cancel();
    _timer = Timer(timeout, () {
      if (_finished) return;
      _finished = true;
      onTimeout();
    });
  }

  void onMessage(String? type) {
    if (_finished) return;
    switch (type) {
      case 'queue':
        _queued = true;
        _timer?.cancel();
      case 'notice':
        if (_queued) {
          _queued = false;
          _arm();
        }
      case 'login':
        close();
    }
  }

  void close() {
    _finished = true;
    _timer?.cancel();
  }
}
