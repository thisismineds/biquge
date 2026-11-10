import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/BookTag.dart';
import 'package:qingyue/entity/Chapter.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/reader/reading_layout.dart';
import 'package:qingyue/storage/app_store.dart';

void main() {
  test('viewport changes invalidate pagination when release Size descriptions are identical', () {
    const style = ReadingStyle();
    const normal = _ReleaseSize(345, 640);
    const fullscreen = _ReleaseSize(345, 780);
    expect(normal.toString(), fullscreen.toString());
    expect(
      readingLayoutSignature(normal, style, 'normal', TextScaler.noScaling),
      isNot(
        readingLayoutSignature(
          fullscreen,
          style,
          'normal',
          TextScaler.noScaling,
        ),
      ),
    );
  });
  testWidgets('hiding reading controls expands and fills the text viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 851);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final content = List.filled(
      80,
      '窗外的树影轻轻摇晃，读书的人继续向前走。每一次翻页，都应该完整显示正文，不留出原本工具栏占用的空白。',
    ).join('\n');
    final tag = BookTag(0, 0, [Chapter(2, 7, '第一章')], '全屏测试');
    SharedPreferences.setMockInitialValues({
      '42': jsonEncode(tag),
      '7': content,
    });
    final store = AppStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ReaderApp(
        store: store,
        home: ReaderScreen(store: store, book: BookInfo.id(42, '全屏测试')),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = find.byType(PageView);
    tester.widget<PageView>(viewport).controller!.jumpToPage(8);
    await tester.pumpAndSettle();
    final beforeHeight = tester.getSize(viewport).height;
    final beforeRecord = store.record(BookInfo.id(42, '全屏测试'))!;
    final beforeOffsets = (beforeRecord['pageOffsets'] as List).cast<int>();
    await tester.tapAt(tester.getCenter(viewport));
    await tester.pumpAndSettle();
    final afterHeight = tester.getSize(viewport).height;
    final afterRecord = store.record(BookInfo.id(42, '全屏测试'))!;
    final afterOffsets = (afterRecord['pageOffsets'] as List).cast<int>();
    expect(afterHeight, greaterThan(beforeHeight + 80));
    expect(afterOffsets.length, lessThan(beforeOffsets.length));
    final savedStart = afterRecord['readerOffset'] as int;
    final page = tester
        .widgetList<ReadingPageView>(find.byType(ReadingPageView))
        .firstWhere((p) => p.page.start == savedStart)
        .page;
    expect(page.height, greaterThan(afterHeight - 55));
    final anchor = beforeRecord['readerOffset'] as int;
    expect(page.start, lessThanOrEqualTo(anchor));
    expect(page.end, greaterThan(anchor));
    await tester.tapAt(tester.getCenter(viewport));
    await tester.pumpAndSettle();
    expect(tester.getSize(viewport).height, beforeHeight);
    expect(
      (store.record(BookInfo.id(42, '全屏测试'))!['pageOffsets'] as List).length,
      beforeOffsets.length,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

// Flutter release/profile builds remove dart:ui diagnostic toString overrides.
class _ReleaseSize extends Size {
  const _ReleaseSize(super.width, super.height);
  @override
  String toString() => 'Instance of Size';
}
