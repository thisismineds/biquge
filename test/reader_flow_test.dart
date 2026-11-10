import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flustars/flustars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:PureBook/entity/BookInfo.dart';
import 'package:PureBook/entity/BookTag.dart';
import 'package:PureBook/entity/Chapter.dart';
import 'package:PureBook/service/book_sources.dart';
import 'package:PureBook/view/BookShelf.dart';
import 'package:PureBook/view/ReadBook.dart';
import 'package:PureBook/view/TopBook.dart';
import 'package:PureBook/view/Search.dart';
import 'package:PureBook/common/common.dart';
import 'package:PureBook/store/Store.dart';
import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await SpUtil.getInstance();
  });
  setUp(() async {
    await SpUtil.clear();
  });

  testWidgets('local bookshelf and three sources work without legacy login',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: BookShelf()));
    expect(find.text('书架还是空的，点击右上角搜索添加小说。'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: TopBook()));
    expect(find.text('笔趣阁 631'), findsOneWidget);
    expect(find.text('酷我小说'), findsOneWidget);
    expect(find.text('新笔趣阁'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached book opens even when every API mirror fails',
      (tester) async {
    final original = BookSources.instance.client.httpClientAdapter;
    BookSources.instance.client.httpClientAdapter =
        FixtureAdapter((_) async => ResponseBody.fromString('', 503));
    addTearDown(() {
      BookSources.instance.client.httpClientAdapter = original;
    });
    final tag = BookTag(0, 4, [Chapter(2, 1, '第一章')], '缓存小说')
      ..content = '离线正文。'
      ..pageOffsets = [1, 2, 3, 4, 5];
    await SpUtil.putString(BookSources.recordKey('bqg631', 1), jsonEncode(tag));
    await SpUtil.putString(BookSources.contentKey('bqg631', 1, 1), '离线正文。');
    final book = BookInfo.id(1, '缓存小说')..sourceId = 'bqg631';
    await tester
        .pumpWidget(Store.init(child: MaterialApp(home: ReadBook(book))));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('离线正文。'), findsOneWidget);
    expect(find.text('第1/1页'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(Container());
    expect(SpUtil.getString(BookSources.contentKey('bqg631', 1, 1)), '离线正文。');
  });

  testWidgets(
      'search opens details, adds the source to shelf and reads a chapter',
      (tester) async {
    // Flutter's test HttpClient rejects external cover images with status 400.
    final reportError = FlutterError.onError;
    FlutterError.onError = (details) {
      final error = details.exception;
      if (error is NetworkImageLoadException && error.statusCode == 400) return;
      reportError(details);
    };
    addTearDown(() {
      FlutterError.onError = reportError;
    });
    BookSources.activeId = 'bqg631';
    final original = BookSources.instance.client.httpClientAdapter;
    BookSources.instance.client.httpClientAdapter = FixtureAdapter((o) async {
      if (o.path.endsWith('/search'))
        return jsonBody({
          'data': [
            {'id': '1', 'title': '测试小说', 'author': '测试作者', 'intro': '说明'}
          ]
        });
      if (o.path.endsWith('/book'))
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
          'lastupdate': '2026-11-10'
        });
      if (o.path.endsWith('/booklist'))
        return jsonBody({
          'list': ['第一章']
        });
      return jsonBody({'txt': '从搜索进入的正文。', 'chapterid': '1'});
    });
    addTearDown(() {
      BookSources.instance.client.httpClientAdapter = original;
    });
    await tester.pumpWidget(Store.init(
        child: MaterialApp(home: Scaffold(body: SearchResult('测试')))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试小说'));
    await tester.pumpAndSettle();
    expect(find.text('作者：测试作者'), findsOneWidget);
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle();
    expect(find.text('从搜索进入的正文。'), findsOneWidget);
    final shelf = jsonDecode(SpUtil.getString(Common.listbookname)) as List;
    expect(shelf.single['sourceId'], 'bqg631');
    expect(shelf.single['Id'], 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(Container());
  });

  testWidgets(
      'chapter transitions restore the previous last page and cached markers',
      (tester) async {
    final original = BookSources.instance.client.httpClientAdapter;
    BookSources.instance.client.httpClientAdapter =
        FixtureAdapter((o) async => jsonBody(o.path.endsWith('/book')
            ? {'dirid': '1'}
            : {
                'list': ['第一章', '第二章']
              }));
    addTearDown(() {
      BookSources.instance.client.httpClientAdapter = original;
    });
    await SpUtil.putString(BookSources.contentKey('bqg631', 1, 1),
        List.filled(500, '甲乙丙丁。').join());
    await SpUtil.putString(BookSources.contentKey('bqg631', 1, 2), '第二章正文。');
    await tester.pumpWidget(Store.init(
        child: MaterialApp(
            home: ReadBook(BookInfo.id(1, '多章小说')..sourceId = 'bqg631'))));
    await tester.pumpAndSettle();
    final dynamic reader = tester.state(find.byType(ReadBook));
    for (var i = 0; i < 20 && find.text('第二章').evaluate().isEmpty; i++) {
      reader.nextPage();
      await tester.pumpAndSettle();
    }
    expect(find.text('第二章正文。'), findsOneWidget);
    reader.prePage();
    await tester.pumpAndSettle();
    final saved =
        jsonDecode(SpUtil.getString(BookSources.recordKey('bqg631', 1)));
    expect(saved['cur'], 0);
    expect(saved['index'], greaterThan(0));
    expect(saved['index'], (saved['pageOffsets'] as List).length - 1);
    final pages = (saved['pageOffsets'] as List).length;
    expect(find.text('第$pages/$pages页'), findsOneWidget);
    final scaffold = tester.state<ScaffoldState>(find
        .descendant(of: find.byType(ReadBook), matching: find.byType(Scaffold))
        .first);
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    expect(find.text('已缓存'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(Container());
  });
}
