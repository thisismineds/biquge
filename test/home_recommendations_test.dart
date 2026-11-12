import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
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
              ],
            });
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
