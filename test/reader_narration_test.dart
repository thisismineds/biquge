import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/reader/reader_narration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('qingyue/tts');
  const codec = StandardMethodCodec();
  const computerAddresses = ['http://192.168.1.20:8767'];
  const updatedAddresses = ['https://pc.example.test'];
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
  Future<void> event(
    String method,
    int id, {
    String? message,
    int? offset,
    bool? ok,
  }) => messenger.handlePlatformMessage(
    channel.name,
    codec.encodeMethodCall(
      MethodCall(method, {
        'id': id,
        'message': message,
        'offset': offset,
        'ok': ok,
      }),
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
    )..computerAddresses = computerAddresses;
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
    'lock preparation waits for audio and plays the prepared first segment',
    () async {
      narration.prepareForLock('跳过。甲段。\n乙段。', offset: 3);
      final queued = calls.where((call) => call.method == 'prepare').toList();
      expect(queued.map(text), ['甲段。\n', '乙段。']);
      expect(spoken(), isEmpty);
      expect(narration.lockPreparation, (ready: 0, total: 2, failed: 0));

      await event('prepared', id(queued.first), ok: true);
      await event('prepared', id(queued.first), ok: true);
      expect(narration.lockPreparation, (ready: 1, total: 2, failed: 0));
      await event('prepared', id(queued.last), ok: true);
      expect(narration.lockPreparation, (ready: 2, total: 2, failed: 0));

      narration.resume();
      expect(narration.lockPreparation, isNull);
      expect(id(spoken().single), id(queued.first));
      expect(calls.where((call) => call.method == 'stop'), isEmpty);
    },
  );

  test('lock preparation invalidates old audio after changing speed', () async {
    narration.prepareForLock('甲段。');
    final prepared = calls.singleWhere((call) => call.method == 'prepare');
    await event('prepared', id(prepared), ok: false);
    expect(narration.lockPreparation, (ready: 0, total: 1, failed: 1));
    narration.rate = 1.5;
    expect(narration.lockPreparation, isNull);
    expect(narration.paused, isFalse);
    expect(calls.last.method, 'stop');
  });

  test(
    'reports spoken offsets and ignores progress from an old utterance',
    () async {
      final offsets = <(int, bool)>[];
      narration.dispose();
      narration = ReaderNarration(
        onChapterFinished: () => chaptersFinished++,
        onError: errors.add,
        onProgress: (offset, {required segmentStarted}) {
          offsets.add((offset, segmentStarted));
        },
      )..computerAddresses = computerAddresses;
      narration.start('跳过。甲🌱乙。\n下一句。', offset: 3);
      final first = id(spoken().single);
      expect(offsets, isEmpty);
      await event('progress', first, offset: 2);
      await event('progress', first, offset: 0);
      await event('progress', first, offset: 200);
      expect(offsets, [(4, true)]);

      await event('finished', first);
      final next = id(spoken().last);
      await event('progress', first, offset: 3);
      await event('progress', next, offset: 0);
      expect(offsets, [(4, true), (8, false), (9, true)]);
    },
  );

  test(
    'pause, address change and resume replay a segment with a fresh ID',
    () async {
      narration.start('跳过。第一句。\n第二句。', offset: 3);
      expect(narration.playing, isTrue);
      final interrupted = spoken().single;
      expect(text(interrupted), '第一句。\n');

      narration.pause();
      expect(narration.paused, isTrue);
      expect(calls.last.method, 'stop');
      narration.computerAddresses = updatedAddresses;
      await event('finished', id(interrupted));
      expect(spoken(), hasLength(1));

      narration.resume();
      final resumed = spoken().last;
      expect(id(resumed), isNot(id(interrupted)));
      expect(text(resumed), text(interrupted));
      expect(resumed.arguments['computerAddresses'], updatedAddresses);
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

  test('keeps a short paragraph together with its punctuation', () async {
    narration.start('他停了一下。然后问，你真的要走吗？\n她点了点头。');
    final first = spoken().single;
    expect(text(first), '他停了一下。然后问，你真的要走吗？\n');
    await event('finished', id(first));
    expect(text(spoken().last), '她点了点头。');
    await event('finished', id(spoken().last));
    expect(chaptersFinished, 1);
  });

  test(
    'computer playback prepares the rest of the chapter immediately',
    () async {
      narration.start('甲段。\n乙段。\n丙段。');
      final first = spoken().single;
      final allPrepared = calls
          .where((call) => call.method == 'prepare')
          .toList();
      expect(allPrepared.map(text), ['乙段。\n', '丙段。']);
      final prepared = allPrepared.first;
      expect(text(prepared), '乙段。\n');
      expect(calls.indexOf(prepared), greaterThan(calls.indexOf(first)));

      await event('finished', id(first));
      expect(id(spoken().last), id(prepared));
      expect(text(spoken().last), text(prepared));
      expect(text(calls.where((call) => call.method == 'prepare').last), '丙段。');

      final oldPreparation = calls.last;
      narration.rate = 1.75;
      expect(calls.where((call) => call.method == 'stop'), hasLength(1));
      expect(id(calls.last), isNot(id(oldPreparation)));
      expect(calls.last.arguments['rate'], 1.75);
    },
  );

  test(
    'prepares only five in the following chapter and reuses their IDs',
    () async {
      final firstChapter = List.generate(7, (i) => '上章第$i段。');
      final nextChapter = List.generate(7, (i) => '下章第$i段。');
      narration.start(firstChapter.join('\n'));
      narration.prepareFollowingChapter(nextChapter.join('\n'));
      final queued = calls.where((call) => call.method == 'prepare').toList();
      expect(queued.map((call) => text(call).trim()), [
        ...firstChapter.skip(1),
        ...nextChapter.take(5),
      ]);
      final nextId = id(queued[firstChapter.length - 1]);
      for (var i = 0; i < firstChapter.length; i++) {
        expect(text(spoken().last).trim(), firstChapter[i]);
        await event('finished', id(spoken().last));
      }
      expect(chaptersFinished, 1);
      expect(calls.where((call) => call.method == 'stop'), isEmpty);

      narration.start(nextChapter.join('\n'), reuseFollowingChapter: true);
      expect(id(spoken().last), nextId);
      expect(text(spoken().last).trim(), nextChapter.first);
      expect(
        calls
            .where((call) => call.method == 'prepare')
            .skip(queued.length)
            .map((call) => text(call).trim()),
        nextChapter.skip(5),
      );
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
      expect(chunks.every((chunk) => chunk.length <= 100), isTrue);
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

  test(
    'changing addresses while playing restarts the active segment',
    () async {
      narration.start('一段正文。');
      final original = spoken().single;
      narration.computerAddresses = updatedAddresses;
      final updated = spoken().last;
      expect(id(updated), isNot(id(original)));
      expect(text(updated), text(original));
      expect(updated.arguments['computerAddresses'], updatedAddresses);
      await event('error', id(original), message: '旧错误');
      expect(errors, isEmpty);
      await event('error', id(updated), message: '语音不可用');
      expect(errors, ['语音不可用']);
      expect(narration.playing, isFalse);
      expect(chaptersFinished, 0);
    },
  );

  test(
    'changing speed retains the sentence and continues at the new rate',
    () async {
      narration.start('第一句。\n第二句。');
      final original = spoken().single;
      expect(original.arguments['rate'], 1.0);

      narration.rate = 2.5;
      final updated = spoken().last;
      expect(calls[calls.indexOf(updated) - 1].method, 'stop');
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
