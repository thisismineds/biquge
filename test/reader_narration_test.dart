import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/reader/reader_narration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('qingyue/tts');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late ReaderNarration narration;
  late List<String> errors;
  late int chaptersFinished;

  List<MethodCall> spoken() =>
      calls.where((call) => call.method == 'speak').toList();
  int id(MethodCall call) => call.arguments['id'] as int;
  String text(MethodCall call) => call.arguments['text'] as String;
  Future<void> event(String method, int id, {String? message}) =>
      messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          MethodCall(method, {'id': id, 'message': message}),
        ),
        (_) {},
      );

  setUp(() {
    calls.clear();
    errors = [];
    chaptersFinished = 0;
    narration = ReaderNarration(
      onChapterFinished: () => chaptersFinished++,
      onError: errors.add,
    )..voice = 'voice-a';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    narration.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'pause, voice change and resume replay a sentence with a fresh ID',
    () async {
      narration.start('跳过。第一句。第二句。', offset: 3);
      expect(narration.playing, isTrue);
      final interrupted = spoken().single;
      expect(text(interrupted), '第一句。');

      narration.pause();
      expect(narration.paused, isTrue);
      expect(calls.last.method, 'stop');
      narration.voice = 'voice-b';
      await event('finished', id(interrupted));
      expect(spoken(), hasLength(1));

      narration.resume();
      final resumed = spoken().last;
      expect(id(resumed), isNot(id(interrupted)));
      expect(text(resumed), text(interrupted));
      expect(resumed.arguments['voice'], 'voice-b');
      await event('finished', id(resumed));
      final next = spoken().last;
      expect(text(next), '第二句。');
      await event('finished', id(next));
      await event('finished', id(next));
      expect(chaptersFinished, 1);
      expect(narration.playing, isFalse);
      expect(narration.paused, isFalse);
      expect(errors, isEmpty);
    },
  );

  test(
    'natural voice keeps a short paragraph together with its punctuation',
    () async {
      narration.voice = 'qingyue:offline-zh';
      narration.start('他停了一下。然后问，你真的要走吗？\n她点了点头。');
      final first = spoken().single;
      expect(text(first), '他停了一下。然后问，你真的要走吗？\n');
      await event('finished', id(first));
      expect(text(spoken().last), '她点了点头。');
      await event('finished', id(spoken().last));
      expect(chaptersFinished, 1);
    },
  );

  test(
    'long utterances preserve text and never split a surrogate pair',
    () async {
      final body = List.filled(300, '书🌱').join();
      final chunks = <String>[];
      narration.start(body);
      while (narration.playing && chunks.length < 10) {
        final call = spoken().last;
        chunks.add(text(call));
        await event('finished', id(call));
      }
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.length <= 250), isTrue);
      expect(
        chunks.every(
          (chunk) => chunk.runes.every((r) => r < 0xd800 || r > 0xdfff),
        ),
        isTrue,
      );
      expect(chunks.join(), body);
      expect(chaptersFinished, 1);
    },
  );

  test('changing voice while playing restarts the active segment', () async {
    narration.start('一段正文。');
    final original = spoken().single;
    narration.voice = 'voice-b';
    final updated = spoken().last;
    expect(id(updated), isNot(id(original)));
    expect(text(updated), text(original));
    expect(updated.arguments['voice'], 'voice-b');
    await event('error', id(original), message: '旧错误');
    expect(errors, isEmpty);
    await event('error', id(updated), message: '语音不可用');
    expect(errors, ['语音不可用']);
    expect(narration.playing, isFalse);
    expect(chaptersFinished, 0);
  });

  test(
    'changing speed retains the sentence and continues at the new rate',
    () async {
      narration.start('第一句。第二句。');
      final original = spoken().single;
      expect(original.arguments['rate'], 1.0);

      narration.rate = 2.5;
      final updated = spoken().last;
      expect(calls[calls.length - 2].method, 'stop');
      expect(id(updated), isNot(id(original)));
      expect(text(updated), text(original));
      expect(updated.arguments['rate'], 2.5);
      await event('finished', id(original));
      expect(spoken(), hasLength(2));

      await event('finished', id(updated));
      expect(text(spoken().last), '第二句。');
      expect(spoken().last.arguments['rate'], 2.5);

      narration.pause();
      narration.rate = double.nan;
      expect(spoken(), hasLength(3));
      narration.resume();
      expect(text(spoken().last), '第二句。');
      expect(spoken().last.arguments['rate'], 1.0);
    },
  );
}
