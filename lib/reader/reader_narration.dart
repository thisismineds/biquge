import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef NarrationVoice = ({String id, String label, bool networkRequired});
typedef _NarrationSegment = ({int id, int end, String text});

class ReaderNarration extends ChangeNotifier {
  ReaderNarration({
    required this.onChapterFinished,
    required this.onError,
    this.onTransport,
  });

  static const playbackRates = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
  static const _channel = MethodChannel('qingyue/tts');
  static final _sentenceEnd = RegExp(r'[。！？!?；;\n]');
  static ReaderNarration? _owner;
  static int _nextId = 0;

  final VoidCallback onChapterFinished;
  final ValueChanged<String> onError;
  final ValueChanged<String>? onTransport;

  String? _text;
  String? _voice;
  double _rate = 1.0;
  int _offset = 0;
  int _segmentEnd = 0;
  int? _utterance;
  _NarrationSegment? _prepared;
  bool _playing = false;
  bool _background = false;

  bool get playing => _playing;
  bool get paused => _text != null && !_playing;

  String? get voice => _voice;

  set voice(String? value) {
    if (_voice == value) return;
    _voice = value;
    _playbackSettingChanged();
  }

  double get rate => _rate;

  set rate(double value) {
    final next = playbackRates.contains(value) ? value : 1.0;
    if (_rate == next) return;
    _rate = next;
    _playbackSettingChanged();
  }

  void _playbackSettingChanged() {
    if (_playing) {
      _endUtterance();
      _speakNext();
    }
    notifyListeners();
  }

  Future<List<NarrationVoice>> voices() async {
    final raw = await _channel.invokeListMethod<Object?>('voices');
    return [
      for (final item in raw ?? const [])
        if (item case {
          'id': final String id,
          'label': final String label,
          'networkRequired': final bool networkRequired,
        })
          (id: id, label: label, networkRequired: networkRequired),
    ];
  }

  Future<void> installVoices() => _channel.invokeMethod<void>('installVoices');

  bool get backgroundActive => _background;

  Future<void> beginBackground(String book, String chapter) async {
    _claimChannel();
    _background = true;
    await _channel.invokeMethod<void>('beginBackground', {
      'book': book,
      'chapter': chapter,
    });
  }

  void updateBackground(String book, String chapter, {required bool playing}) {
    if (!_background) return;
    unawaited(
      _sendBackground('updateBackground', {
        'book': book,
        'chapter': chapter,
        'playing': playing,
      }),
    );
  }

  void endBackground() {
    if (!_background) return;
    _background = false;
    unawaited(_sendBackground('endBackground'));
    _releaseChannel();
  }

  Future<void> _sendBackground(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // The Android service may already have stopped.
    } on MissingPluginException {
      // The activity may already have detached.
    }
  }

  void _claimChannel() {
    if (_owner != this) {
      _owner?.stop();
      _owner?.endBackground();
      _owner = this;
      _channel.setMethodCallHandler(_handleEvent);
    }
  }

  void start(String text, {int offset = 0, bool paused = false}) {
    _claimChannel();
    _endUtterance();
    _text = text;
    _offset = offset.clamp(0, text.length);
    if (_offset > 0 &&
        _offset < text.length &&
        _isLowSurrogate(text.codeUnitAt(_offset))) {
      _offset--;
    }
    _playing = !paused;
    if (_playing) _speakNext();
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    _endUtterance();
    notifyListeners();
  }

  void resume() {
    if (!paused) return;
    _playing = true;
    _speakNext();
    notifyListeners();
  }

  void stop() {
    if (_text == null) return;
    _reset();
    notifyListeners();
  }

  void _speakNext() {
    final current = _prepared ?? _segmentAt(_offset);
    _prepared = null;
    if (current != null) {
      _segmentEnd = current.end;
      _utterance = current.id;
      unawaited(_sendSegment('speak', current));
      if (_usesOfflineVoice) {
        final next = _segmentAt(current.end);
        if (next != null) {
          _prepared = next;
          unawaited(_sendSegment('prepare', next));
        }
      }
      return;
    }
    _reset();
    notifyListeners();
    onChapterFinished();
  }

  bool get _usesOfflineVoice =>
      _voice == null || _voice!.startsWith('qingyue:offline-zh');

  _NarrationSegment? _segmentAt(int offset) {
    final text = _text!;
    final offline = _usesOfflineVoice;
    while (offset < text.length) {
      var limit = math.min(offset + (offline ? 100 : 250), text.length);
      if (limit < text.length && _isLowSurrogate(text.codeUnitAt(limit))) {
        limit--;
      }
      final end = _readableBoundary(text, offset, limit, offline);
      final segment = text.substring(offset, end);
      if (segment.trim().isNotEmpty) {
        return (id: ++_nextId, end: end, text: segment);
      }
      offset = end;
    }
    return null;
  }

  int _readableBoundary(String text, int offset, int limit, bool natural) {
    final section = text.substring(offset, limit);
    var sentences = 0, lastBoundary = 0;
    for (final breakPoint in _sentenceEnd.allMatches(section)) {
      lastBoundary = breakPoint.end;
      if (!natural || breakPoint[0] == '\n' || ++sentences == 3) {
        return offset + lastBoundary;
      }
    }
    // Keep neighboring sentences together so the model sees their punctuation and context.
    return limit < text.length && lastBoundary >= 40
        ? offset + lastBoundary
        : limit;
  }

  Future<void> _sendSegment(String method, _NarrationSegment segment) async {
    try {
      await _channel.invokeMethod<void>(method, {
        'id': segment.id,
        'text': segment.text,
        'rate': _rate,
        if (_voice != null) 'voice': _voice,
      });
    } on PlatformException catch (error) {
      if (method == 'speak') {
        _fail(segment.id, error.message ?? '语音引擎暂时无法朗读。');
      }
    } on MissingPluginException {
      if (method == 'speak') _fail(segment.id, '当前设备不支持系统朗读。');
    }
  }

  Future<void> _handleEvent(MethodCall call) async {
    final args = call.arguments;
    if (call.method == 'transport') {
      if (_background && args is Map) {
        final action = args['action'];
        if (action is String) onTransport?.call(action);
      }
      return;
    }
    if (args is! Map || args['id'] is! int || args['id'] != _utterance) return;
    if (call.method == 'finished') {
      _utterance = null;
      _offset = _segmentEnd;
      _speakNext();
    } else if (call.method == 'error') {
      final message = args['message'];
      _fail(args['id'] as int, message is String ? message : '朗读中断，请重试。');
    }
  }

  void _fail(int id, String message) {
    if (id != _utterance) return;
    _reset();
    notifyListeners();
    onError(message);
  }

  void _endUtterance() {
    if (_utterance == null && _prepared == null) return;
    _utterance = null;
    _prepared = null;
    unawaited(_stopEngine());
  }

  Future<void> _stopEngine() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // The engine may already have shut down.
    } on MissingPluginException {
      // The controller may run without an Android engine.
    }
  }

  void _reset() {
    _endUtterance();
    _text = null;
    _playing = false;
    _releaseChannel();
  }

  void _releaseChannel() {
    if (_owner == this && !_background && _text == null) {
      _owner = null;
      _channel.setMethodCallHandler(null);
    }
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

  @override
  void dispose() {
    _reset();
    endBackground();
    super.dispose();
  }
}
