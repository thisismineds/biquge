import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/Chapter.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/reader/reader_screen.dart';
import 'package:qingyue/reader/reading_layout.dart';
import 'package:qingyue/storage/app_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStore> load() async =>
      AppStore(await SharedPreferences.getInstance());

  test('spacing and margin presets apply and survive reload without changing other data', () async {
    SharedPreferences.setMockInitialValues({
      'bg_i': 4,
      'reader.fontSize': 25.0,
      '42': 'saved progress',
    });
    final store = await load();
    const spacings = {
      'small': (1.35, 4.0),
      'compact': (1.5, 8.0),
      'comfortable': (1.75, 12.0),
      'large': (2.0, 20.0),
    };
    for (final entry in spacings.entries) {
      await store.setSpacingPreset(entry.key);
      final restored = await load();
      expect(restored.spacingPresetId, entry.key);
      expect(restored.readingStyle.lineHeight, entry.value.$1);
      expect(restored.readingStyle.paragraphGap, entry.value.$2);
      expect(restored.backgroundIndex, 4);
      expect(restored.readingStyle.fontSize, 25);
      expect(restored.preferences.getString('42'), 'saved progress');
    }
    for (final entry in {
      'small': 16.0,
      'normal': 24.0,
      'wide': 32.0,
      'large': 40.0,
    }.entries) {
      await store.setMarginPreset(entry.key);
      final restored = await load();
      expect(restored.marginPresetId, entry.key);
      expect(restored.readingStyle.horizontalPadding, entry.value);
    }
    await store.setMarginPreset('smart');
    expect((await load()).marginPresetId, 'smart');
  });

  test('existing manual typography infers presets or custom without resetting values', () async {
    SharedPreferences.setMockInitialValues({
      'reader.lineHeight': 1.5,
      'reader.paragraphGap': 8.0,
      'reader.padding': 32.0,
    });
    final matching = await load();
    expect(matching.spacingPresetId, 'compact');
    expect(matching.marginPresetId, 'wide');
    SharedPreferences.setMockInitialValues({
      'reader.lineHeight': 1.65,
      'reader.paragraphGap': 10.0,
      'reader.padding': 28.0,
    });
    final custom = await load();
    expect(custom.spacingPresetId, 'custom');
    expect(custom.marginPresetId, 'custom');
    expect(custom.readingStyle.lineHeight, 1.65);
    expect(custom.readingStyle.paragraphGap, 10);
    expect(custom.effectiveReadingStyle(800).horizontalPadding, 28);
    await custom.setReadingStyle(custom.readingStyle.copyWith(fontSize: 28));
    expect(custom.spacingPresetId, 'custom');
    expect(custom.marginPresetId, 'custom');
    await matching.setSpacingPreset('large');
    await matching.setMarginPreset('smart');
    await matching.setReadingStyle(
      matching.readingStyle.copyWith(fontSize: 27),
    );
    expect(matching.spacingPresetId, 'large');
    expect(matching.marginPresetId, 'smart');
  });

  testWidgets(
    'Settings opens all requested choices and custom controls remember values',
    (tester) async {
      final store = await load();
      await tester.pumpWidget(ReaderApp(store: store));
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.text('字号与显示'), findsOneWidget);
      await tester.tap(find.text('间距设置'));
      await tester.pumpAndSettle();
      expect(find.text('行段间距'), findsOneWidget);
      expect(find.text('页面边距'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(10));
      expect(find.byType(Slider), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '自定义'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNWidgets(2));
      tester.widget<Slider>(find.byType(Slider).at(0)).onChanged!(1.8);
      await tester.pumpAndSettle();
      tester.widget<Slider>(find.byType(Slider).at(1)).onChanged!(16);
      await tester.pumpAndSettle();
      expect(store.spacingPresetId, 'custom');
      final restored = await load();
      expect(restored.spacingPresetId, 'custom');
      expect(restored.readingStyle.lineHeight, 1.8);
      expect(restored.readingStyle.paragraphGap, 16);
      await restored.setSpacingPreset('small');
      await restored.setSpacingPreset('custom');
      expect(restored.readingStyle.lineHeight, 1.8);
      expect(restored.readingStyle.paragraphGap, 16);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader shortcut safely replaces its sheet with spacing settings',
    (tester) async {
      final store = await load();
      await tester.pumpWidget(
        ReaderApp(
          store: store,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showReadingSettings(context, store),
                child: const Text('打开阅读设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('间距设置'));
      await tester.pumpAndSettle();
      expect(find.text('行段间距'), findsOneWidget);
      expect(find.byTooltip('关闭阅读设置'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'smart spacing uses screen width consistently for reader and pagination',
    (tester) async {
      final store = await load();
      await store.setMarginPreset('smart');
      final book = BookInfo.id(42, '智能页边距');
      final raw = List.filled(20, '同样的文字保持连贯，页面随屏幕宽度调整。🌿').join('\n');
      await store.preferences.setString(
        '42chapters',
        jsonEncode([Chapter(2, 7, '第一章')]),
      );
      await store.preferences.setString('7', raw);
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      tester.view.devicePixelRatio = 1;
      for (final width in [360.0, 800.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpWidget(
          ReaderApp(
            store: store,
            home: ReaderScreen(store: store, book: book),
          ),
        );
        await tester.pumpAndSettle();
        final expectedPadding = width == 360 ? 21.6 : 120.0;
        final style = store.effectiveReadingStyle(width);
        expect(style.horizontalPadding, closeTo(expectedPadding, .001));
        final viewport = tester.getSize(find.byType(PageView));
        expect(viewport.width, closeTo(width - expectedPadding * 2, .001));
        final pages = paginateChapter(formatChapter(raw), viewport, style);
        expect(
          pages.map((p) => formatChapter(raw).substring(p.start, p.end)).join(),
          formatChapter(raw),
        );
        final rendered = tester.widget<ReadingPageView>(
          find.byType(ReadingPageView).first,
        );
        expect(
          rendered.style.horizontalPadding,
          closeTo(expectedPadding, .001),
        );
        expect(rendered.page.end, pages.first.end);
        final fragments = find.descendant(
          of: find.byType(ReadingPageView).first,
          matching: find.byType(RichText),
        );
        for (var i = 0; i < rendered.page.fragments.length; i++) {
          expect(
            tester.getSize(fragments.at(i)).height,
            closeTo(rendered.page.fragments[i].height, .01),
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
