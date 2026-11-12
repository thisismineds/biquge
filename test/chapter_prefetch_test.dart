import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'reader fills the next three chapters and tops up on chapter change',
    (tester) async {
      final requests = <int>[];
      final client = Dio()
        ..httpClientAdapter = FixtureAdapter((o) async {
          if (o.path.endsWith('/chapters')) {
            return jsonBody({
              'data': [
                for (var i = 1; i <= 6; i++)
                  {'chapter_id': '$i', 'chapter_title': '第$i章'},
              ],
            });
          }
          final id = int.parse(o.uri.pathSegments.last);
          requests.add(id);
          return jsonBody({
            'data': {'content': '第$id章的测试正文。'},
          });
        });
      final store = AppStore(
        await SharedPreferences.getInstance(),
        sources: BookSources(client: client),
      );
      final book = BookInfo.id(42, '预缓存测试')..sourceId = 'kuwo';
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, [1, 2, 3, 4]);
      expect(store.hasCachedChapter(book, 4), isTrue);
      expect(store.hasCachedChapter(book, 5), isFalse);

      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('第2章的测试正文。', findRichText: true),
        findsOneWidget,
      );
      expect(requests, [1, 2, 3, 4, 5]);
      expect(store.hasCachedChapter(book, 5), isTrue);
      expect(store.hasCachedChapter(book, 6), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('simultaneous readers share an unfinished chapter request', () async {
    final entered = Completer<void>();
    final response = Completer<ResponseBody>();
    var requests = 0;
    final client = Dio()
      ..httpClientAdapter = FixtureAdapter((_) async {
        if (++requests == 1) entered.complete();
        return response.future;
      });
    final store = AppStore(
      await SharedPreferences.getInstance(),
      sources: BookSources(client: client),
    );
    final book = BookInfo.id(42, '并发测试')..sourceId = 'kuwo';
    final prefetch = store.loadContent(book, 2);
    await entered.future;
    final open = store.loadContent(book, 2);
    response.complete(
      jsonBody({
        'data': {'content': '第二章正文。'},
      }),
    );
    expect(await Future.wait([prefetch, open]), ['第二章正文。', '第二章正文。']);
    expect(requests, 1);
  });
}
