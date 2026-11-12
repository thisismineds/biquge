import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
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
