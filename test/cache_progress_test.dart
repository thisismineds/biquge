import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/service/book_sources.dart';
import 'package:qingyue/storage/app_store.dart';
import 'package:qingyue/ui/cache_progress_button.dart';
import 'package:qingyue/ui/book_details.dart';

import 'book_sources_test.dart' show FixtureAdapter, jsonBody;

void main() {
  testWidgets('a chapter finishing after pause still updates the paused ring', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final pending = Completer<ResponseBody>();
    final client = Dio()
      ..httpClientAdapter = FixtureAdapter((o) async {
        if (o.path.endsWith('/book')) return jsonBody({'dirid': '42'});
        if (o.path.endsWith('/booklist')) {
          return jsonBody({
            'list': ['第一章', '第二章', '第三章'],
          });
        }
        return pending.future;
      });
    final store = AppStore(
      await SharedPreferences.getInstance(),
      sources: BookSources(client: client),
    );
    final book = BookInfo.id(42, '暂停中的缓存')..sourceId = 'bqg631';
    await store.preferences.setString(store.contentKey(book, 1), '已有缓存正文。');
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: BookDetails(store: store, book: book),
      ),
    );
    await tester.tap(find.byTooltip('离线缓存'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('33%'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停缓存'));
    await tester.pump();
    pending.complete(jsonBody({'txt': '暂停时完成的第二章'}));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(find.text('66%'), findsOneWidget);
    expect(find.byTooltip('继续缓存'), findsOneWidget);
    expect(store.preferences.getString(store.contentKey(book, 2)), '暂停时完成的第二章');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'near-complete thousands of chapters fit at enlarged system text',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Center(
                child: CacheProgressButton(
                  active: true,
                  cached: 12499,
                  total: 12500,
                  tooltip: '缓存',
                  onPressed: null,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('99%'), findsOneWidget);
      expect(
        tester.getSize(find.byType(IconButton)).shortestSide,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'details pause and resume keep the percentage and never add a body progress row',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pending = <Completer<ResponseBody>>[];
      final client = Dio()
        ..httpClientAdapter = FixtureAdapter((o) async {
          if (o.path.endsWith('/book')) return jsonBody({'dirid': '42'});
          if (o.path.endsWith('/booklist')) {
            return jsonBody({
              'list': ['第一章', '第二章', '第三章'],
            });
          }
          final next = Completer<ResponseBody>();
          pending.add(next);
          return next.future;
        });
      final store = AppStore(
        await SharedPreferences.getInstance(),
        sources: BookSources(client: client),
      );
      final book = BookInfo.id(42, '缓存进度')..sourceId = 'bqg631';
      await store.preferences.setString(store.contentKey(book, 1), '已有缓存正文。');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: BookDetails(store: store, book: book),
        ),
      );
      await tester.tap(find.byTooltip('离线缓存'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('33%'), findsOneWidget);
      pending.first.complete(jsonBody({'txt': '第二章正文'}));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(find.text('66%'), findsOneWidget);
      await tester.tap(find.byTooltip('暂停缓存'));
      await tester.pump();
      await tester.tap(find.byTooltip('继续缓存'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('66%'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      pending.last.complete(jsonBody({'txt': '第三章正文'}));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('已缓存 2 / 3'), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.preferences.getString(store.contentKey(book, 3)), '第三章正文');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('large chapter counts stay outside the compact percentage ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CacheProgressButton(
              active: true,
              cached: 345,
              total: 12500,
              tooltip: '缓存',
              onPressed: null,
            ),
          ),
        ),
      ),
    );
    expect(find.text('2%'), findsOneWidget);
    expect(find.text('345/12500'), findsNothing);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      closeTo(.0276, .00001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'directory loading is indeterminate and completion shows a check',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CacheProgressButton(
              active: true,
              cached: 0,
              total: 0,
              tooltip: '准备缓存',
              onPressed: null,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CacheProgressButton(
              active: false,
              cached: 12500,
              total: 12500,
              tooltip: '缓存完成',
              onPressed: () {},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader advances actual cache progress and updates the open directory',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pending = <Completer<ResponseBody>>[];
      final client = Dio()
        ..httpClientAdapter = FixtureAdapter((o) async {
          if (o.path.endsWith('/book')) return jsonBody({'dirid': '42'});
          if (o.path.endsWith('/booklist')) {
            return jsonBody({
              'list': ['第一章', '第二章', '第三章'],
            });
          }
          final next = Completer<ResponseBody>();
          pending.add(next);
          return next.future;
        });
      final store = AppStore(
        await SharedPreferences.getInstance(),
        sources: BookSources(client: client),
      );
      final book = BookInfo.id(42, '缓存进度')..sourceId = 'bqg631';
      await store.preferences.setString(store.contentKey(book, 1), '已有缓存正文。');
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: ReaderScreen(store: store, book: book),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('从当前章缓存'));
      await tester.pump();
      await tester.pump();
      expect(find.text('33%'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 20));
      pending.first.complete(jsonBody({'txt': '第二章正文'}));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('66%'), findsOneWidget);
      await tester.tap(find.byTooltip('章节目录'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已缓存 2 章'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      pending.last.complete(jsonBody({'txt': '第三章正文'}));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('已缓存 3 章'), findsOneWidget);
      expect(store.preferences.getString(store.contentKey(book, 3)), '第三章正文');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
