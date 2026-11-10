import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/app/reader_theme.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/BookTag.dart';
import 'package:qingyue/entity/Chapter.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:qingyue/ui/search_screen.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStore> storeWith(
    Future<ResponseBody> Function(RequestOptions) respond,
  ) async {
    final client = Dio()..httpClientAdapter = FixtureAdapter(respond);
    return AppStore(
      await SharedPreferences.getInstance(),
      sources: BookSources(client: client),
    );
  }

  testWidgets('load more keeps the submitted query after the input is edited', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final store = await storeWith((request) async {
      requests.add(request.queryParameters);
      return jsonBody({
        'data': [
          {
            'book_id': '${requests.length}',
            'title': '结果${requests.length}',
            'cover_url': '',
            'intro': '简介',
          },
        ],
      });
    });
    await store.selectSource('kuwo');
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: SearchScreen(store: store),
      ),
    );
    await tester.enterText(find.byType(TextField), 'A');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'B');
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(requests.map((r) => r['keyword']), ['A', 'A']);
    expect(requests.map((r) => r['pi']), [1, 2]);
    expect(find.text('结果1'), findsWidgets);
    expect(find.text('结果2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'settings retain the old background and persist all five choices',
    (tester) async {
      SharedPreferences.setMockInitialValues({'bg_i': 3});
      final store = await storeWith((_) async => jsonBody({'data': []}));
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showReadingSettings(context, store),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      expect(store.backgroundIndex, 3);
      for (var i = 0; i < 5; i++) {
        final choice = find.byTooltip('阅读背景 ${i + 1}');
        expect(choice, findsOneWidget);
        final size = tester.getSize(choice);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(store.backgroundIndex, i);
        expect(store.preferences.getInt('bg_i'), i);
        expect(AppStore(store.preferences).backgroundIndex, i);
      }
    },
  );

  testWidgets(
    'reader footer target and ink remain accessible and title truncates',
    (tester) async {
      final store = await storeWith(
        (_) async => ResponseBody.fromString('', 503),
      );
      final book = BookInfo.id(1, List.filled(20, '长书名').join());
      await store.preferences.setString(
        '1chapters',
        jsonEncode([Chapter(2, 7, '第一章')]),
      );
      await store.preferences.setString('7', '缓存正文。');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      final cache = tester.getSize(find.byTooltip('从当前章缓存'));
      expect(cache.width, greaterThanOrEqualTo(48));
      expect(cache.height, greaterThanOrEqualTo(48));
      final title = tester.widget<Text>(find.text(book.Name));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      final footer = tester.widget<Text>(find.text('1 / 1 章'));
      for (final background in ReaderTheme.readingBackgrounds) {
        final ink = Color.alphaBlend(footer.style!.color!, background);
        expect(
          (background.computeLuminance() + .05) /
              (ink.computeLuminance() + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
      await store.setDark(true);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        const Color(0xFF262626),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('retry of the previous chapter returns to its final page', (
    tester,
  ) async {
    var attempts = 0;
    final text = List.filled(500, '甲乙丙丁。').join();
    final store = await storeWith((request) async {
      if (request.path.endsWith('/chapters')) {
        return jsonBody({
          'data': [
            {'chapter_id': 1, 'chapter_title': '第一章'},
            {'chapter_id': 2, 'chapter_title': '第二章'},
          ],
        });
      }
      attempts++;
      if (attempts == 1) return ResponseBody.fromString('', 503);
      return jsonBody({
        'data': {'content': text},
      });
    });
    final book = BookInfo.id(1, '重试小说')..sourceId = 'kuwo';
    await store.preferences.setString(store.contentKey(book, 2), '第二章正文。');
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: ReaderScreen(store: store, book: book, chapterIndex: 1),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(700, 0));
    await tester.pumpAndSettle();
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    final saved = store.record(book)!;
    expect(saved['cur'], 0);
    expect(saved['index'], greaterThan(0));
    expect(saved['index'], (saved['pageOffsets'] as List).length - 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retry of saved progress retains the saved text offset', (
    tester,
  ) async {
    var attempts = 0;
    final text = List.filled(500, '甲乙丙丁。').join();
    final store = await storeWith((request) async {
      if (request.path.endsWith('/chapters')) {
        return jsonBody({
          'data': [
            {'chapter_id': 1, 'chapter_title': '第一章'},
          ],
        });
      }
      attempts++;
      if (attempts == 1) return ResponseBody.fromString('', 503);
      return jsonBody({
        'data': {'content': text},
      });
    });
    final book = BookInfo.id(1, '恢复小说')..sourceId = 'kuwo';
    final tag = BookTag(0, 0, [Chapter(1, 1, '第一章')], book.Name)
      ..content = text;
    await store.preferences.setString(
      store.key(book),
      jsonEncode(tag.toJson()..['readerOffset'] = 1500),
    );
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: ReaderScreen(store: store, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    final saved = store.record(book)!;
    expect(saved['index'], greaterThan(0));
    expect(saved['readerOffset'], greaterThan(0));
    expect(saved['readerOffset'], lessThanOrEqualTo(1502));
    expect(
      (saved['pageOffsets'] as List)[saved['index'] as int],
      greaterThan(1502),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
