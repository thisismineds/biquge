import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/main.dart' as app show main;
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/reader/reading_layout.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _computerAddresses = ['http://192.168.1.20:8767'];

void main() {
  testWidgets('app startup shares saved PC addresses with the system engine', (
    tester,
  ) async {
    const channel = MethodChannel('qingyue/tts');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'reader.narrationComputerAddresses': _computerAddresses,
    });

    await app.main();
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.method), ['setSystemSpeechServers']);
    expect(calls.single.arguments['computerAddresses'], _computerAddresses);
  });

  testWidgets(
    'reader saves multiple PC addresses and uses them for listening',
    (tester) async {
      const channel = MethodChannel('qingyue/tts');
      const addresses = ['http://192.168.1.20:8767', 'https://pc.example.test'];
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({
        'reader.narrationVoice': 'qingyue:offline-zh-clear',
        'reader.narrationRate': 2.0,
        '42chapters': jsonEncode([
          {'id': 51, 'name': '第一章', 'hasContent': 2},
          {'id': 52, 'name': '第二章', 'hasContent': 2},
        ]),
        '51': '第一章第一段。\n第一章第二段。',
        '52': '第二章第一段。',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final book = BookInfo.id(42, '电脑合成测试');
      Future<void> openListening() async {
        await tester.pumpWidget(
          ReaderApp(
            store: store,
            home: ReaderScreen(store: store, book: book),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('听书'));
        await tester.pumpAndSettle();
      }

      await openListening();
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(find.text('电脑合成设置'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.enterText(
        find.byType(TextFormField),
        'http://user@192.168.1.20:8767',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 行不是有效的电脑地址。'), findsOneWidget);
      expect(prefs.getStringList('reader.narrationComputerAddresses'), isNull);

      await tester.enterText(
        find.byType(TextFormField),
        '192.168.1.20\nhttps://pc.example.test/\nhttp://192.168.1.20:8767/',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        prefs.getStringList('reader.narrationComputerAddresses'),
        addresses,
      );
      Iterable<dynamic> systemAddresses() => calls
          .where((call) => call.method == 'setSystemSpeechServers')
          .map((call) => call.arguments['computerAddresses']);
      expect(systemAddresses(), [addresses]);
      await tester.pumpWidget(const SizedBox());
      await openListening();
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'prepare'), hasLength(2));
      expect(calls.where((call) => call.method == 'speak'), hasLength(1));
      for (final call in calls.where(
        (call) => call.method == 'speak' || call.method == 'prepare',
      )) {
        expect(call.arguments, isNot(contains('voice')));
        expect(call.arguments['rate'], 2.0);
        expect(call.arguments['computerAddresses'], addresses);
      }

      await tester.tap(find.byTooltip('电脑合成设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(prefs.getStringList('reader.narrationComputerAddresses'), isEmpty);
      expect(systemAddresses(), [addresses, <String>[]]);
      expect(calls.where((call) => call.method == 'speak'), hasLength(1));
      expect(
        calls.where((call) => call.method == 'endBackground'),
        hasLength(1),
      );
      expect(find.text('播放'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reader prepares the chapter before starting lock-screen playback',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      const channel = MethodChannel('qingyue/tts');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({
        'reader.narrationComputerAddresses': _computerAddresses,
        'reader.narrationRate': 1.5,
        '42chapters': jsonEncode([
          {'id': 51, 'name': '第一章', 'hasContent': 2},
          {'id': 52, 'name': '第二章', 'hasContent': 2},
        ]),
        '51': '第一章第一段。\n第一章第二段。',
        '52': '第二章第一段。',
      });
      final store = AppStore(await SharedPreferences.getInstance());
      final book = BookInfo.id(42, '锁屏准备测试');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('听书'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('锁屏准备'));
      await tester.pumpAndSettle();

      Iterable<MethodCall> methods(String name) =>
          calls.where((call) => call.method == name);
      final current = methods('prepare')
          .where((call) => call.arguments['text'].contains('第一章'))
          .toList();
      expect(current, hasLength(2));
      expect(methods('prepare'), hasLength(3));
      expect(methods('speak'), isEmpty);
      expect(methods('beginBackground'), isEmpty);
      expect(find.text('准备本章音频 0/2 段'), findsOneWidget);

      for (final call in current) {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('prepared', {'id': call.arguments['id'], 'ok': true}),
          ),
          (_) {},
        );
        await tester.pump();
      }
      expect(find.text('本章音频已准备，播放后可锁屏'), findsOneWidget);
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(methods('beginBackground'), hasLength(1));
      final first = methods('speak').single.arguments;
      expect(first['id'], current.first.arguments['id']);
      expect(first['computerAddresses'], _computerAddresses);
      expect(first['rate'], 1.5);
      expect(find.text('本章音频已准备，播放后可锁屏'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reader reuses the five prepared segments of the next chapter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    const channel = MethodChannel('qingyue/tts');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    String chapterText(String title) =>
        List.generate(7, (i) => '$title第${i + 1}段。').join('\n');
    SharedPreferences.setMockInitialValues({
      'reader.narrationComputerAddresses': _computerAddresses,
      'reader.narrationRate': 2.0,
      '42chapters': jsonEncode([
        {'id': 51, 'name': '第一章', 'hasContent': 2},
        {'id': 52, 'name': '第二章', 'hasContent': 2},
        {'id': 53, 'name': '第三章', 'hasContent': 2},
      ]),
      '51': '第一章有声音。',
      '52': chapterText('第二章'),
      '53': chapterText('第三章'),
    });
    final store = AppStore(await SharedPreferences.getInstance());
    final book = BookInfo.id(42, '下一章准备测试');
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: ReaderScreen(store: store, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('听书'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();

    Iterable<MethodCall> spoken() => calls.where((c) => c.method == 'speak');
    List<MethodCall> prepared(String chapter) => calls
        .where(
          (c) => c.method == 'prepare' && c.arguments['text'].contains(chapter),
        )
        .toList();
    final first = spoken().single;
    final following = prepared('第二章');
    expect(following, hasLength(5));
    expect(prepared('第三章'), isEmpty);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('finished', {'id': first.arguments['id']}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(spoken(), hasLength(2));
    expect(spoken().last.arguments['id'], following.first.arguments['id']);
    expect(prepared('第三章'), hasLength(5));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reader follows background audio and resumes from a browsed page',
    (tester) async {
      tester.view.physicalSize = const Size(320, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('qingyue/tts');
      const codec = StandardMethodCodec();
      final messenger = tester.binding.defaultBinaryMessenger;
      final utterances = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'speak') {
          utterances.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final raw = List.generate(30, (i) => '第${i + 1}处石桥边有灯😀亮着，').join();
      SharedPreferences.setMockInitialValues({
        'reader.narrationComputerAddresses': _computerAddresses,
        '42chapters': jsonEncode([
          {'id': 51, 'name': '第一章', 'hasContent': 2},
        ]),
        '51': raw,
      });
      final store = AppStore(await SharedPreferences.getInstance());
      final book = BookInfo.id(42, '听书翻页测试');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('听书'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();

      Future<void> event(String method, Map<String, Object?> args) async {
        await messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall(method, args)),
          (ByteData? _) {},
        );
        await tester.pump();
      }

      final ends = (store.record(book)!['pageOffsets'] as List).cast<int>();
      final first = utterances.single;
      final secondStart = (first['text'] as String).length;
      final pageBeforeBoundary = ends.indexWhere((end) => secondStart < end);
      final followedPage = pageBeforeBoundary + 1;
      final browsedPage = followedPage + 1;
      expect(pageBeforeBoundary, greaterThan(0));
      expect(browsedPage, lessThan(ends.length));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await event('finished', {'id': first['id']});
      expect(utterances, hasLength(2));
      final second = utterances.last;
      final spokenOffset = ends[pageBeforeBoundary] + 3 - secondStart;
      expect((second['text'] as String).length, greaterThan(spokenOffset));
      await event('progress', {'id': second['id'], 'offset': spokenOffset});
      expect(store.record(book)?['index'], followedPage);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('第${followedPage + 1}/${ends.length}页'), findsOneWidget);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        followedPage + 1,
      );

      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-310, 0));
      await tester.pumpAndSettle();
      expect(find.text('第${browsedPage + 1}/${ends.length}页'), findsOneWidget);
      final browsedStart = ends[browsedPage - 1];
      expect(store.record(book)?['readerOffset'], browsedStart);
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(utterances, hasLength(3));
      final resumed = utterances.last['text'] as String;
      expect(resumed, isNotEmpty);
      expect(formatChapter(raw).substring(browsedStart), startsWith(resumed));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reader plays through the chapter boundary using computer synthesis',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('qingyue/tts');
      const codec = StandardMethodCodec();
      final messenger = tester.binding.defaultBinaryMessenger;
      final utterances = <Map<Object?, Object?>>[];
      final background = <MethodCall>[];
      var stops = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'speak':
            utterances.add(call.arguments as Map<Object?, Object?>);
          case 'stop':
            stops++;
          case 'beginBackground':
          case 'updateBackground':
          case 'endBackground':
            background.add(call);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({
        'reader.narrationComputerAddresses': _computerAddresses,
        '42chapters': jsonEncode([
          {'id': 51, 'name': '第一章', 'hasContent': 2},
          {'id': 52, 'name': '第二章', 'hasContent': 2},
        ]),
        '51': '第一章有声音。',
        '52': '第二章接着念。',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final book = BookInfo.id(42, '听书测试');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('听书'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('朗读倍速'));
      await tester.pumpAndSettle();
      for (final label in [
        'x1.25',
        'x1.50',
        'x1.75',
        'x2.00',
        'x2.50',
        'x3.00',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<double>, 'x1.75'),
      );
      await tester.pumpAndSettle();
      expect(prefs.getDouble('reader.narrationRate'), 1.75);
      expect(find.text('x1.75'), findsOneWidget);

      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect((utterances.single['text'] as String).trim(), '第一章有声音。');
      expect(utterances.single['computerAddresses'], _computerAddresses);
      expect(utterances.single['rate'], 1.75);
      final firstId = utterances.single['id'];
      expect(background.first.method, 'beginBackground');

      Future<void> event(String method, Map<String, Object?> args) async {
        await messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall(method, args)),
          (ByteData? _) {},
        );
        await tester.pump();
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(stops, 0);
      await event('transport', {'action': 'pause'});
      expect(stops, 1);
      await event('transport', {'action': 'resume'});
      expect(utterances, hasLength(2));
      await event('finished', {'id': firstId});
      expect(utterances, hasLength(2));
      await event('finished', {'id': utterances.last['id']});
      expect((utterances.last['text'] as String).trim(), '第二章接着念。');
      expect(store.record(book)?['cur'], 1);
      expect(
        background.where((call) => call.method == 'beginBackground'),
        hasLength(1),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('第二章'), findsOneWidget);
      expect((utterances.last['text'] as String).trim(), '第二章接着念。');
      expect(utterances.last['computerAddresses'], _computerAddresses);
      expect(utterances.last['rate'], 1.75);
      await tester.tap(find.byTooltip('结束听书'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('听书'), findsOneWidget);
      expect(background.last.method, 'endBackground');
      expect(tester.takeException(), isNull);
    },
  );
}
