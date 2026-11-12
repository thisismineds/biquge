import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:qingyue/ui/recommendation_list_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  testWidgets('home switches to the new source and browses its next catalog page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'activeSourceId': 'kuwo'});
    final pages = <int>[];
    final client = Dio()
      ..httpClientAdapter = FixtureAdapter((o) async {
        if (o.uri.host != 'www.biquges123.com') {
          return jsonBody({
            'hotlist': [
              {'id': 1, 'title': '原书源推荐'},
            ],
          });
        }
        if (o.path == '/xh' || o.uri.path == '/xh') {
          final page = int.tryParse(o.uri.queryParameters['page'] ?? '') ?? 1;
          pages.add(page);
          return ResponseBody.fromString(
            '<main><div class="class"><ul class="hot_4"><li>'
            '<a href="/${page + 10}"><div class="hot_name">第$page 页书籍</div></a>'
            '</li></ul></div>'
            '${page == 1 ? '<div class="page"><a href="/xh?page=2">下一页</a></div>' : ''}</main>',
            200,
          );
        }
        return ResponseBody.fromString('''
        <main>
          <div class="hot"><ul class="hot_4"><li><a href="/11"><div class="hot_name">新来源精选</div></a></li></ul></div>
          <div class="fenlei_item"><h2><a href="/xh">玄幻奇幻</a></h2><ul><li><a href="/11">新来源玄幻</a></li></ul></div>
          <div class="update"><ul><li><a href="/12">新来源更新</a><a class="chapter" href="/12/2">第二章</a><time>2026-11-12</time></li></ul></div>
        </main>
      ''', 200);
      });
    final prefs = await SharedPreferences.getInstance();
    final store = AppStore(prefs, sources: BookSources(client: client));
    await tester.pumpWidget(ReaderApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换首页书源'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '新笔趣阁'));
    await tester.pumpAndSettle();
    expect(find.text('新来源更新'), findsWidgets);
    expect(find.text('原书源推荐'), findsNothing);
    expect(prefs.getString('home.sourceId'), 'biquges123');
    expect(store.sourceId, 'kuwo');
    await tester.tap(find.widgetWithText(ChoiceChip, '玄幻奇幻'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('玄幻奇幻更多'));
    await tester.pumpAndSettle();
    expect(find.text('第1 页书籍'), findsWidgets);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('第2 页书籍'), findsWidgets);
    expect(find.text('第1 页书籍'), findsWidgets);
    expect(pages, [1, 2]);
  });

  testWidgets('retry advances to unqueried books after a group of failures', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final books = [
      for (var i = 1; i <= 9; i++) BookInfo.id(i, '示例书$i')..sourceId = 'bqg631',
    ];
    final requested = <String>{};
    final client = Dio()
      ..httpClientAdapter = FixtureAdapter((o) async {
        final id = o.queryParameters['id'] as String;
        requested.add(id);
        return id == '9'
            ? jsonBody({'id': 9, 'title': '示例书9', 'lastupdate': '2026-11-12'})
            : ResponseBody.fromString('', 404);
      });
    final store = AppStore(
      await SharedPreferences.getInstance(),
      sources: BookSources(client: client),
    );
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: RecommendationListScreen(
          store: store,
          title: '玄幻奇幻',
          preview: books,
          loadCatalog: (_) async => (books: books, hasMore: false),
          allowUpdateSort: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '最近更新'));
    await tester.pumpAndSettle();
    expect(requested, isNot(contains('9')));
    await tester.tap(find.text('补查'));
    await tester.pumpAndSettle();
    expect(requested, contains('9'));
    expect(find.text('2026-11-12 更新'), findsOneWidget);
  });

  test(
    'recent updates sort newest first and retain source order on the same day',
    () async {
      final now = DateTime.now().toUtc().add(const Duration(hours: 8));
      final today = now.toIso8601String().split('T').first;
      final yesterday = now
          .subtract(const Duration(days: 1))
          .toIso8601String()
          .split('T')
          .first;
      final client = Dio()
        ..httpClientAdapter = FixtureAdapter(
          (_) async => jsonBody({
            'uplist': [
              {'id': 1, 'title': '旧更新', 'uptime': yesterday},
              {
                'id': 2,
                'title': '今日更新甲',
                'uptime': today.substring(5),
                'lastchapter': '最新一章',
              },
              {'id': 3, 'title': '今日更新乙', 'uptime': today},
            ],
          }),
        );
      final data = await BookSources(client: client).recommendations();
      expect(data['uplist']?.map((b) => b.Id), [2, 3, 1]);
      expect(data['uplist']?.first.LastChapter, '最新一章');
    },
  );

  testWidgets(
    'home opens a category and its book, and keeps selection across tabs',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'activeSourceId': 'kuwo'});
      var feeds = 0;
      final detailIds = <String>[];
      final catalogs = <String>[];
      final client = Dio()
        ..httpClientAdapter = FixtureAdapter((o) async {
          if (o.path.endsWith('/index')) {
            feeds++;
            return jsonBody({
              'hotlist': [
                {'id': 1, 'title': '综合示例', 'author': '示例作者'},
                {'id': 'bad', 'title': '无效条目'},
              ],
              'sort1': [
                {'id': '12', 'title': '玄幻示例', 'author': '分类作者'},
              ],
            });
          }
          if (o.path.endsWith('/sort')) {
            catalogs.add(o.queryParameters['sort'] as String);
            return jsonBody({
              'data': [
                {'id': 13, 'title': '更多分类书籍', 'author': '另一位作者'},
                {'id': 15, 'title': '日期未知的书'},
                {'id': 14, 'title': '刚更新的书', 'author': '更新作者'},
              ],
            });
          }
          if (o.queryParameters['id'] == '13') {
            return jsonBody({
              'id': 13,
              'title': '更多分类书籍',
              'lastupdate': '2025-01-01',
            });
          }
          if (o.queryParameters['id'] == '14') {
            return jsonBody({
              'id': 14,
              'title': '刚更新的书',
              'lastupdate': '2026-11-12',
            });
          }
          if (o.queryParameters['id'] == '15') {
            return jsonBody({'id': 15, 'title': '日期未知的书'});
          }
          detailIds.add(o.queryParameters['id'] as String);
          return jsonBody({
            'id': '12',
            'title': '玄幻示例',
            'author': '分类作者',
            'intro': '测试简介',
          });
        });
      final store = AppStore(
        await SharedPreferences.getInstance(),
        sources: BookSources(client: client),
      );
      await tester.pumpWidget(ReaderApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('综合推荐'), findsOneWidget);
      expect(find.text('综合示例'), findsWidgets);
      expect(find.text('无效条目'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '玄幻奇幻'));
      await tester.pumpAndSettle();
      expect(find.text('玄幻示例'), findsWidgets);
      expect(find.text('综合示例'), findsNothing);
      await tester.tap(find.byTooltip('玄幻奇幻更多'));
      await tester.pumpAndSettle();
      expect(catalogs, ['xuanhuan']);
      expect(find.text('更多分类书籍'), findsWidgets);
      await tester.tap(find.widgetWithText(ChoiceChip, '最近更新'));
      await tester.pumpAndSettle();
      expect(find.text('2026-11-12 更新'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('刚更新的书').last).dy,
        lessThan(tester.getTopLeft(find.text('更多分类书籍').last).dy),
      );
      expect(
        tester.getTopLeft(find.text('日期未知的书').last).dy,
        greaterThan(tester.getTopLeft(find.text('更多分类书籍').last).dy),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '书源顺序'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('更多分类书籍').last).dy,
        lessThan(tester.getTopLeft(find.text('刚更新的书').last).dy),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('玄幻示例').last);
      await tester.pumpAndSettle();
      expect(detailIds, ['12']);
      expect(find.text('书籍详情'), findsOneWidget);
      expect(find.text('测试简介'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('书架').last);
      await tester.pumpAndSettle();
      expect(find.text('下一本好书，等你翻开'), findsOneWidget);
      await tester.tap(find.text('首页').last);
      await tester.pumpAndSettle();
      expect(find.text('玄幻示例'), findsWidgets);
      expect(feeds, 1);
      expect(store.sourceId, 'kuwo');
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(find.text('玄幻示例'), findsWidgets);
      expect(feeds, 1);
      tester.view.physicalSize = const Size(320, 700);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
