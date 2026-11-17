import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/reader/reading_layout.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
    'reader remembers a voice and plays through the chapter boundary',
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
      var installs = 0, voiceQueries = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'voices':
            voiceQueries++;
            return [
              if (installs > 0)
                {
                  'id': 'test-voice',
                  'label': '测试普通话音色',
                  'networkRequired': false,
                },
            ];
          case 'installVoices':
            installs++;
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
      await tester.tap(find.text('音色'));
      await tester.pumpAndSettle();
      expect(find.text('测试普通话音色'), findsNothing);
      await tester.tap(find.text('系统语音设置'));
      await tester.pumpAndSettle();
      expect(installs, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(voiceQueries, 2);
      await tester.tap(find.text('测试普通话音色'));
      await tester.pumpAndSettle();
      expect(prefs.getString('reader.narrationVoice'), 'test-voice');
      expect(utterances, isEmpty);

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
      expect(utterances.single['voice'], 'test-voice');
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
      expect(utterances.last['voice'], 'test-voice');
      expect(utterances.last['rate'], 1.75);
      await tester.tap(find.byTooltip('结束听书'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('听书'), findsOneWidget);
      expect(background.last.method, 'endBackground');
      expect(tester.takeException(), isNull);
    },
  );
}
