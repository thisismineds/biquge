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
  test('the first switch uses this chapter’s fallback even after another chapter loads', () async {
    SharedPreferences.setMockInitialValues({});
    final requested = <String>[];
    var failPrimary = true;
    final store = AppStore(
      await SharedPreferences.getInstance(),
      sources: BookSources(
        client: Dio()
          ..httpClientAdapter = FixtureAdapter((o) async {
            requested.add(o.uri.host);
            if (o.uri.host == 'apibi.cc' && failPrimary) {
              failPrimary = false;
              return ResponseBody.fromString('', 503);
            }
            return jsonBody({'txt': '备用接口正文。'});
          }),
      ),
    );
    final book = BookInfo.id(42, '测试书')..sourceId = 'bqg631';
    await store.loadContent(book, 1);
    await store.loadContent(book, 2);
    await store.advanceBqgHost(book, chapterId: 1);
    await store.loadContent(book, 1, refresh: true);
    expect(requested, ['apibi.cc', 'apiqu.cc', 'apibi.cc', 'apige.cc']);
  });

  testWidgets(
    'switch replaces only the current cache and remembers each mirror',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'content:bqg631:42:1': '原来缓存的错文。',
        'content:bqg631:42:2': '原有的第二章缓存。',
      });
      final requested = <String>[];
      var failThird = true;
      BookSources sources() => BookSources(
        client: Dio()
          ..httpClientAdapter = FixtureAdapter((o) async {
            if (o.path.endsWith('/book')) return jsonBody({'dirid': '42'});
            if (o.path.endsWith('/booklist')) {
              return jsonBody({
                'list': ['第一章', '第二章'],
              });
            }
            final host = o.uri.host;
            requested.add(host);
            if (host == 'apige.cc' && failThird) {
              return ResponseBody.fromString('', 503);
            }
            return jsonBody({'txt': '来自 $host 的正文。'});
          }),
      );
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs, sources: sources());
      final book = BookInfo.id(42, '测试书')..sourceId = 'bqg631';
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      expect(requested, isEmpty);

      Future<void> tapSwitch() async {
        await tester.tap(find.byTooltip('更换章节内容'));
        await tester.pumpAndSettle();
      }

      await tapSwitch();
      expect(requested, ['apiqu.cc']);
      expect(prefs.getString('content:bqg631:42:1'), '来自 apiqu.cc 的正文。');
      expect(
        find.textContaining('apiqu.cc 的正文', findRichText: true),
        findsOneWidget,
      );

      final reopened = AppStore(prefs, sources: sources());
      final otherBook = BookInfo.id(43, '另一本测试书')..sourceId = 'bqg631';
      final second = reopened.loadContent(otherBook, 2);
      await tester.pump(const Duration(milliseconds: 20));
      expect(await second, '来自 apiqu.cc 的正文。');

      await tapSwitch();
      expect(requested.last, 'apige.cc');
      expect(prefs.getString('content:bqg631:42:1'), '来自 apiqu.cc 的正文。');
      expect(
        find.textContaining('apiqu.cc 的正文', findRichText: true),
        findsOneWidget,
      );

      failThird = false;
      await tapSwitch();
      expect(requested, ['apiqu.cc', 'apiqu.cc', 'apige.cc', 'apibi.cc']);
      expect(prefs.getString('content:bqg631:42:1'), '来自 apibi.cc 的正文。');
      expect(prefs.getString('content:bqg631:42:2'), '原有的第二章缓存。');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
