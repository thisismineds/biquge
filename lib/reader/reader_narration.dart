import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef NarrationVoice = ({String id, String label, bool networkRequired});
typedef _NarrationSegment = ({int id, int start, int end, String text});

class ReaderNarration extends ChangeNotifier {
  ReaderNarration({
    required this.onChapterFinished,
    required this.onError,
    this.onTransport,
    this.onProgress,
  });

  static const playbackRates = [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
  static const computerVoice = 'qingyue:offline-zh-pc';
  static const _channel = MethodChannel('qingyue/tts');
  static const _followingChapterSegments = 5;
  static final _sentenceEnd = RegExp(r'[。！？!?；;\n]');
  static ReaderNarration? _owner;
  static int _nextId = 0;

  final VoidCallback onChapterFinished;
  final ValueChanged<String> onError;
  final ValueChanged<String>? onTransport;
  final void Function(int offset, {required bool segmentStarted})? onProgress;

  String? _text;
  String? _voice;
  List<String> _computerAddresses = const [];
  double _rate = 1.0;
  int _offset = 0;
  _NarrationSegment? _active;
  int? _reportedOffset;
  final _prepared = Queue<_NarrationSegment>();
  final _following = <_NarrationSegment>[];
  final _lockPending = <int>{};
  int _lockTotal = 0, _lockFailed = 0;
  bool _preparationScreenOn = false;
  String? _followingText;
  bool _playing = false;
  bool _background = false;

  bool get playing => _playing;
  bool get paused => _text != null && !_playing;
  bool get preparesAudio =>
      _voice == null || _voice!.startsWith('qingyue:offline-zh');
  ({int ready, int total, int failed})? get lockPreparation => _lockTotal == 0
      ? null
      : (
          ready: _lockTotal - _lockPending.length - _lockFailed,
          total: _lockTotal,
          failed: _lockFailed,
        );

  String? get voice => _voice;

  set voice(String? value) {
    final next = value == computerVoice && _computerAddresses.isEmpty
        ? null
        : value;
    if (_voice == next) return;
    _voice = next;
    _playbackSettingChanged();
  }

  List<String> get computerAddresses => _computerAddresses;

  set computerAddresses(List<String> value) {
    if (listEquals(_computerAddresses, value)) return;
    _computerAddresses = List.unmodifiable(value);
    if (_voice == computerVoice) {
      if (value.isEmpty) _voice = null;
      _playbackSettingChanged();
    }
  }

  double get rate => _rate;

  set rate(double value) {
    final next = playbackRates.contains(value) ? value : 1.0;
    if (_rate == next) return;
    _rate = next;
    _playbackSettingChanged();
  }

  void _playbackSettingChanged() {
    final preparedForLock = lockPreparation != null;
    _endUtterance();
    if (_playing) {
      _speakNext();
    } else if (preparedForLock) {
      _text = null;
      _releaseChannel();
    }
    notifyListeners();
  }

  Future<List<NarrationVoice>> voices() async {
    final raw = await _channel.invokeListMethod<Object?>(
      'voices',
      _computerAddresses.isEmpty
          ? null
          : {'computerAddresses': _computerAddresses},
    );
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

  void start(
    String text, {
    int offset = 0,
    bool paused = false,
    bool reuseFollowingChapter = false,
  }) {
    _claimChannel();
    if (reuseFollowingChapter &&
        _text == null &&
        offset == 0 &&
        text == _followingText) {
      _prepared.addAll(_following);
      _following.clear();
      _followingText = null;
    } else {
      _endUtterance();
    }
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

  void prepareForLock(String text, {int offset = 0}) {
    if (!preparesAudio) return;
    start(text, offset: offset, paused: true);
    _prepared.addAll(_segmentsFrom(text, _offset));
    _lockTotal = _prepared.length;
    if (_lockTotal == 0) {
      stop();
      return;
    }
    _lockPending.addAll(_prepared.map((segment) => segment.id));
    _setPreparationScreenOn(true);
    for (final segment in _prepared) {
      unawaited(_sendSegment('prepare', segment));
    }
    notifyListeners();
  }

  void resume() {
    if (!paused) return;
    _endLockPreparation();
    _playing = true;
    _speakNext();
    notifyListeners();
  }

  void stop() {
    if (_text == null && _following.isEmpty) return;
    _reset();
    notifyListeners();
  }

  void _speakNext() {
    final chapter = _text!;
    final current = _prepared.isNotEmpty
        ? _prepared.removeFirst()
        : _segmentAt(chapter, _offset);
    if (current != null) {
      _active = current;
      _reportedOffset = null;
      unawaited(_sendSegment('speak', current));
      if (preparesAudio) {
        final end = _prepared.isEmpty ? current.end : _prepared.last.end;
        for (final next in _segmentsFrom(chapter, end)) {
          _prepared.addLast(next);
          unawaited(_sendSegment('prepare', next));
        }
      }
      return;
    }
    // Keep the next chapter's prepared audio available for the chapter hand-off.
    _text = null;
    _playing = false;
    _releaseChannel();
    notifyListeners();
    onChapterFinished();
  }

  void prepareFollowingChapter(String text) {
    if ((!playing && lockPreparation == null) ||
        !preparesAudio ||
        _followingText != null ||
        text.isEmpty) {
      return;
    }
    _followingText = text;
    var end = 0;
    for (var i = 0; i < _followingChapterSegments; i++) {
      final next = _segmentAt(text, end);
      if (next == null) break;
      end = next.end;
      _following.add(next);
      unawaited(_sendSegment('prepare', next));
    }
  }

  Iterable<_NarrationSegment> _segmentsFrom(String text, int offset) sync* {
    var next = _segmentAt(text, offset);
    while (next != null) {
      yield next;
      next = _segmentAt(text, next.end);
    }
  }

  _NarrationSegment? _segmentAt(String text, int offset) {
    final offline = preparesAudio;
    while (offset < text.length) {
      var limit = math.min(offset + (offline ? 100 : 250), text.length);
      if (limit < text.length && _isLowSurrogate(text.codeUnitAt(limit))) {
        limit--;
      }
      final end = _readableBoundary(text, offset, limit, offline);
      final segment = text.substring(offset, end);
      if (segment.trim().isNotEmpty) {
        return (id: ++_nextId, start: offset, end: end, text: segment);
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
        if (_voice == computerVoice) 'computerAddresses': _computerAddresses,
      });
    } on PlatformException catch (error) {
      if (method == 'speak') {
        _fail(segment.id, error.message ?? '语音引擎暂时无法朗读。');
      } else {
        _settleLockSegment(segment.id, false);
      }
    } on MissingPluginException {
      if (method == 'speak') {
        _fail(segment.id, '当前设备不支持系统朗读。');
      } else {
        _settleLockSegment(segment.id, false);
      }
    }
  }

  Future<void> _handleEvent(MethodCall call) async {
    final args = call.arguments;
    if (call.method == 'prepared') {
      if (args case {'id': final int id, 'ok': final bool ok}) {
        _settleLockSegment(id, ok);
      }
      return;
    }
    if (call.method == 'transport') {
      if (_background && args is Map) {
        final action = args['action'];
        if (action is String) onTransport?.call(action);
      }
      return;
    }
    final active = _active;
    if (active == null ||
        args is! Map ||
        args['id'] is! int ||
        args['id'] != active.id) {
      return;
    }
    if (call.method == 'progress') {
      final offset = args['offset'];
      if (offset is int && offset >= 0 && offset < active.text.length) {
        _reportProgress(active, offset);
      }
    } else if (call.method == 'finished') {
      _reportProgress(active, active.text.length - 1);
      _active = null;
      _offset = active.end;
      _speakNext();
    } else if (call.method == 'error') {
      final message = args['message'];
      _fail(active.id, message is String ? message : '朗读中断，请重试。');
    }
  }

  void _reportProgress(_NarrationSegment segment, int offset) {
    if (offset > 0 && _isLowSurrogate(segment.text.codeUnitAt(offset))) {
      offset--;
    }
    final position = segment.start + offset;
    final previous = _reportedOffset;
    if (previous != null && position <= previous) return;
    _reportedOffset = position;
    onProgress?.call(position, segmentStarted: previous == null);
  }

  void _fail(int id, String message) {
    if (id != _active?.id) return;
    _reset();
    notifyListeners();
    onError(message);
  }

  void _endUtterance() {
    _endLockPreparation();
    final hadAudio =
        _active != null || _prepared.isNotEmpty || _following.isNotEmpty;
    _active = null;
    _prepared.clear();
    _following.clear();
    _followingText = null;
    if (hadAudio) unawaited(_stopEngine());
  }

  void _settleLockSegment(int id, bool ok) {
    if (!_lockPending.remove(id)) return;
    if (!ok) _lockFailed++;
    if (_lockPending.isEmpty) _setPreparationScreenOn(false);
    notifyListeners();
  }

  void _setPreparationScreenOn(bool value) {
    if (_preparationScreenOn == value) return;
    _preparationScreenOn = value;
    unawaited(_sendBackground('keepPreparationScreenOn', value));
  }

  void _endLockPreparation() {
    _lockPending.clear();
    _lockTotal = 0;
    _lockFailed = 0;
    _setPreparationScreenOn(false);
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
