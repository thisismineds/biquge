import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/BookTag.dart';
import 'package:qingyue/entity/Chapter.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/ui/search_screen.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  Future<AppStore> storeWith(
    Future<ResponseBody> Function(RequestOptions) respond,
  ) async {
    final client = Dio()..httpClientAdapter = FixtureAdapter(respond);
    return AppStore(
      await SharedPreferences.getInstance(),
      sources: BookSources(client: client),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'local bookshelf and source selection do not require legacy login',
    (tester) async {
      final store = await storeWith((_) async => jsonBody({'data': []}));
      await tester.pumpWidget(ReaderApp(store: store));
      await tester.tap(find.text('书架').last);
      await tester.pumpAndSettle();
      expect(find.text('下一本好书，等你翻开'), findsOneWidget);
      await tester.tap(find.text('书源').last);
      await tester.pumpAndSettle();
      expect(find.text('笔趣阁 631'), findsOneWidget);
      expect(find.text('酷我小说'), findsOneWidget);
      expect(find.text('新笔趣阁'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached old book opens with all sources offline and preserves background',
    (tester) async {
      final store = await storeWith(
        (_) async => ResponseBody.fromString('', 503),
      );
      final tag = BookTag(0, 4, [Chapter(2, 7, '第一章')], '缓存小说')
        ..content = '离线正文。'
        ..pageOffsets = [1, 2, 3, 4, 5];
      await store.preferences.setString('1', jsonEncode(tag));
      await store.preferences.setString('1chapters', jsonEncode(tag.chapters));
      await store.preferences.setString('7', '离线正文。');
      final book = BookInfo.id(1, '缓存小说');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget);
      expect(find.textContaining('离线正文。', findRichText: true), findsOneWidget);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, const Color(0xFFF6F2EA));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('search opens details and reads with source retained in shelf', (
    tester,
  ) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException &&
          (details.exception as NetworkImageLoadException).statusCode == 400) {
        return;
      }
      previous?.call(details);
    };
    addTearDown(() {
      FlutterError.onError = previous;
    });
    final store = await storeWith((o) async {
      if (o.path.endsWith('/search')) {
        return jsonBody({
          'data': [
            {'id': '1', 'title': '测试小说', 'author': '测试作者', 'intro': '说明'},
          ],
        });
      }
      if (o.path.endsWith('/book')) {
        return jsonBody({
          'id': '1',
          'title': '测试小说',
          'author': '测试作者',
          'intro': '说明',
          'sortname': '测试',
          'full': '连载',
          'dirid': '1',
          'lastchapterid': '1',
          'lastchapter': '第一章',
          'lastupdate': '2026-11-10',
        });
      }
      if (o.path.endsWith('/booklist')) {
        return jsonBody({
          'list': ['第一章'],
        });
      }
      return jsonBody({'txt': '从搜索进入的正文。', 'chapterid': '1'});
    });
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: SearchScreen(store: store),
      ),
    );
    await tester.enterText(find.byType(TextField), '测试');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试小说').last);
    await tester.pumpAndSettle();
    expect(find.text('测试作者'), findsOneWidget);
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('从搜索进入的正文。', findRichText: true),
      findsOneWidget,
    );
    expect(store.shelf.single.sourceId, 'bqg631');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('multi-page chapters move back to the previous last page', (
    tester,
  ) async {
    final store = await storeWith(
      (o) async => jsonBody(
        o.path.endsWith('/book')
            ? {'dirid': '1'}
            : {
                'list': ['第一章', '第二章'],
              },
      ),
    );
    final book = BookInfo.id(1, '多章小说')..sourceId = 'bqg631';
    await store.preferences.setString(
      store.contentKey(book, 1),
      List.filled(500, '甲乙丙丁。').join(),
    );
    await store.preferences.setString(store.contentKey(book, 2), '第二章正文。');
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: ReaderScreen(store: store, book: book),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 30 && find.text('第二章').evaluate().isEmpty; i++) {
      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('第二章正文。', findRichText: true), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(700, 0));
    await tester.pumpAndSettle();
    final saved = store.record(book)!;
    expect(saved['cur'], 0);
    expect(saved['index'], greaterThan(0));
    expect(saved['index'], (saved['pageOffsets'] as List).length - 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
