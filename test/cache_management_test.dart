import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/BookTag.dart';
import 'package:qingyue/entity/Chapter.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/reader/reading_layout.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStore> seeded() async {
    final store = AppStore(await SharedPreferences.getInstance());
    for (final source in ['bqg631', 'kuwo', 'legacy']) {
      final book = BookInfo.id(42, '$source 示例书')..sourceId = source;
      await store.add(book);
      await store.preferences.setString(store.contentKey(book, 7), '缓存正文');
      final tag = BookTag(0, 0, [Chapter(2, 7, '第一章')], book.Name)
        ..content = '阅读记录中重复的正文';
      await store.saveProgress(book, tag, 12);
      await store.preferences.setString(
        store.chaptersKey(book),
        jsonEncode(tag.chapters),
      );
    }
    return store;
  }

  test(
    'removing a shelf book deletes its local data and keeps other sources',
    () async {
      final store = await seeded();
      await store.remove(
        store.shelf.singleWhere((b) => b.sourceId == 'bqg631'),
      );
      expect(store.preferences.containsKey('content:bqg631:42:7'), isFalse);
      expect(store.preferences.containsKey('record:bqg631:42'), isFalse);
      expect(
        store.preferences.containsKey('record:bqg631:42:chapters'),
        isFalse,
      );
      expect(store.preferences.containsKey('info:record:bqg631:42'), isFalse);
      expect(store.preferences.getString('content:kuwo:42:7'), '缓存正文');
      expect(store.preferences.getString('7'), '缓存正文');
      expect(AppStore(store.preferences).shelf.length, 2);
    },
  );

  test(
    'clearing cache preserves shelf and position but removes embedded text',
    () async {
      final store = await seeded();
      final book = BookInfo.id(42, '缓存管理')..sourceId = 'bqg631';
      await store.clearCache(book);
      expect(store.contains(book), isTrue);
      expect(store.hasCachedChapter(book, 7), isFalse);
      expect(store.record(book)?['readerOffset'], 12);
      expect(store.record(book)?['content'], isNull);
      expect(store.preferences.getString('content:kuwo:42:7'), '缓存正文');
      expect(
        store.cachedBooks.map((b) => b.sourceId),
        unorderedEquals(['kuwo', 'legacy']),
      );
    },
  );

  test(
    'legacy cleanup uses its directory and leaves unrelated numeric keys',
    () async {
      final store = await seeded();
      await store.preferences.setString('99', '另一本文字');
      await store.clearCache(BookInfo.id(42, '旧书'));
      expect(store.preferences.containsKey('7'), isFalse);
      expect(store.preferences.getString('99'), '另一本文字');
      expect(store.record(BookInfo.id(42, '旧书'))?['readerOffset'], 12);
      expect(store.preferences.getString('content:bqg631:42:7'), '缓存正文');
    },
  );

  test(
    'cache discovery prefers metadata over content-key fallback names',
    () async {
      SharedPreferences.setMockInitialValues({
        'content:bqg631:42:7': '有归属的缓存',
        'info:record:bqg631:42': jsonEncode(
          BookInfo.id(42, '正确书名')..sourceId = 'bqg631',
        ),
        'content:bqg631:420:7': '另一本文字',
      });
      final store = AppStore(await SharedPreferences.getInstance());
      expect(store.cachedBooks.map((b) => b.Name), contains('正确书名'));
      await store.clearCache(BookInfo.id(42, '')..sourceId = 'bqg631');
      expect(store.preferences.getString('content:bqg631:420:7'), '另一本文字');
    },
  );

  testWidgets('shelf removal deletes cache only after confirmation', (
    tester,
  ) async {
    final store = await seeded();
    await tester.pumpWidget(ReaderApp(store: store));
    await tester.tap(find.text('书架').last);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('bqg631 示例书').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(store.shelf.length, 3);
    await tester.longPress(find.text('bqg631 示例书').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移出并删除'));
    await tester.pumpAndSettle();
    expect(store.shelf.length, 2);
    expect(store.preferences.containsKey('content:bqg631:42:7'), isFalse);
    expect(find.text('bqg631 示例书'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'legacy chapter cleanup cannot delete another book reading record',
    () async {
      final store = await seeded();
      final other = BookTag(0, 0, [Chapter(2, 100, '他书章节')], '另一本旧书');
      await store.preferences.setString('7', jsonEncode(other));
      await store.clearCache(BookInfo.id(42, '旧书'));
      expect(store.preferences.getString('7'), jsonEncode(other));
    },
  );

  testWidgets(
    'reopening after cache deletion preserves formatted text position',
    (tester) async {
      final raw = List.generate(
        500,
        (i) => '第$i 段文字在窗边延续，书页翻动，安静的故事仍在继续。',
      ).join('\n');
      final dio = Dio()
        ..httpClientAdapter = FixtureAdapter((o) async {
          if (o.path.endsWith('/book')) return jsonBody({'dirid': '42'});
          if (o.path.endsWith('/booklist')) {
            return jsonBody({
              'list': ['第一章'],
            });
          }
          return jsonBody({'txt': raw});
        });
      final store = AppStore(
        await SharedPreferences.getInstance(),
        sources: BookSources(client: dio),
      );
      final book = BookInfo.id(42, '恢复位置')..sourceId = 'bqg631';
      await store.add(book);
      await store.preferences.setString(store.contentKey(book, 1), raw);
      await store.saveProgress(
        book,
        BookTag(0, 0, [Chapter(2, 1, '第一章')], book.Name)
          ..content = formatChapter(raw),
        10000,
      );
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      final before = store.record(book)!['readerOffset'];
      expect(before, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await store.clearCache(book);
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.record(book)!['readerOffset'], before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('cache list finds books previously removed from shelf', () async {
    final store = await seeded();
    await store.preferences.setString('booklist', '[]');
    final reopened = AppStore(store.preferences);
    expect(reopened.cachedBooks.map((b) => b.Name), contains('bqg631 示例书'));
    await reopened.clearCache(BookInfo.id(42, '')..sourceId = 'bqg631');
    expect(reopened.preferences.containsKey('content:bqg631:42:7'), isFalse);
    expect(reopened.shelf, isEmpty);
  });

  test(
    'a pending response cannot recreate cleared cache and a new request can',
    () async {
      final pending = Completer<ResponseBody>();
      final entered = Completer<void>();
      var calls = 0;
      final dio = Dio()
        ..httpClientAdapter = FixtureAdapter((_) async {
          if (++calls == 1) {
            entered.complete();
            return pending.future;
          }
          return jsonBody({'txt': '重新下载正文'});
        });
      final store = AppStore(
        await SharedPreferences.getInstance(),
        sources: BookSources(client: dio),
      );
      final book = BookInfo.id(42, '下载中的书')..sourceId = 'bqg631';
      await store.add(book);
      final download = store.loadContent(book, 7);
      final rejected = expectLater(download, throwsA(isA<SourceException>()));
      await entered.future;
      await store.clearCache(book);
      pending.complete(jsonBody({'txt': '过期响应正文'}));
      await rejected;
      expect(store.hasCachedChapter(book, 7), isFalse);
      expect(await store.loadContent(book, 7), '重新下载正文');
    },
  );

  testWidgets(
    'local storage deletes one book cache without removing the shelf entry',
    (tester) async {
      final store = await seeded();
      await tester.pumpWidget(ReaderApp(store: store));
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地保存'));
      await tester.pumpAndSettle();
      expect(find.text('缓存管理'), findsOneWidget);
      await tester.tap(find.byTooltip('删除 bqg631 示例书 的缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(store.preferences.containsKey('content:bqg631:42:7'), isTrue);
      await tester.tap(find.byTooltip('删除 bqg631 示例书 的缓存'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除缓存'));
      await tester.pumpAndSettle();
      expect(store.preferences.containsKey('content:bqg631:42:7'), isFalse);
      expect(store.shelf.length, 3);
      expect(
        store.record(BookInfo.id(42, '')..sourceId = 'bqg631')?['readerOffset'],
        12,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
