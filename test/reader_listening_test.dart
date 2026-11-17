import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'reader remembers a voice and plays through the chapter boundary',
    (tester) async {
      const channel = MethodChannel('qingyue/tts');
      const codec = StandardMethodCodec();
      final messenger = tester.binding.defaultBinaryMessenger;
      final utterances = <Map<Object?, Object?>>[];
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
      await tester.tap(find.text('下载更多音色'));
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

      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect((utterances.single['text'] as String).trim(), '第一章有声音。');
      expect(utterances.single['voice'], 'test-voice');
      final firstId = utterances.single['id'];

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('继续'), findsOneWidget);
      expect(stops, greaterThan(0));
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(utterances, hasLength(2));

      Future<void> complete(Object? id) async {
        await messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall('finished', {'id': id})),
          (ByteData? _) {},
        );
        await tester.pumpAndSettle();
      }

      await complete(firstId);
      expect(utterances, hasLength(2));
      await complete(utterances.last['id']);
      expect(find.text('第二章'), findsOneWidget);
      expect((utterances.last['text'] as String).trim(), '第二章接着念。');
      expect(utterances.last['voice'], 'test-voice');
      await tester.tap(find.byTooltip('结束听书'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('听书'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
