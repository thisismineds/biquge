import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingyue/reader/reading_layout.dart';

void main() {
  testWidgets('scaled fragments render at exactly their measured heights', (
    tester,
  ) async {
    const size = Size(312, 465);
    const style = ReadingStyle();
    const scaler = TextScaler.linear(1.3);
    final text = formatChapter(
      List.filled(12, '窗外的树影轻轻摇晃，读书的人继续向前走。🌿').join('\n'),
    );
    final pages = paginateChapter(text, size, style, textScaler: scaler);
    expect(pages.map((p) => text.substring(p.start, p.end)).join(), text);
    for (final page in pages) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            textTheme: const TextTheme(
              bodyMedium: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: .8,
                height: 1.5,
              ),
            ),
          ),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: scaler),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: ReadingPageView(
                    page: page,
                    style: style,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final fragments = find.descendant(
        of: find.byType(ReadingPageView),
        matching: find.byType(RichText),
      );
      expect(fragments, findsNWidgets(page.fragments.length));
      for (var i = 0; i < page.fragments.length; i++) {
        final richText = tester.widget<RichText>(fragments.at(i));
        expect(richText.locale, const Locale('zh', 'CN'));
        expect(richText.text.style!.inherit, isFalse);
        expect(richText.textScaler.scale(21), scaler.scale(21));
        expect(
          tester.getSize(fragments.at(i)).height,
          closeTo(page.fragments[i].height, .01),
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  test('paragraphs keep their text and gain a clear first-line indent', () {
    expect(
      formatChapter('  第一段。\r\n\r\n　　第二段。\n第三段。'),
      '　　第一段。\n\n　　第二段。\n\n　　第三段。',
    );
    expect(formatChapter('a  b\t c'), '　　a b c');
  });

  test(
    'pagination covers every UTF-16 unit without repeats or broken emoji',
    () {
      final text = formatChapter(
        List.filled(12, '窗外的树影轻轻摇晃，读书的人继续向前走。🌿').join('\n'),
      );
      final pages = paginateChapter(
        text,
        const Size(180, 220),
        const ReadingStyle(),
      );
      expect(pages.length, greaterThan(1));
      expect(pages.map((p) => text.substring(p.start, p.end)).join(), text);
      for (final p in pages) {
        expect(p.height, lessThanOrEqualTo(220.01));
        expect(p.end, greaterThan(p.start));
        if (p.end < text.length) {
          expect(
            text.codeUnitAt(p.end),
            isNot(inInclusiveRange(0xDC00, 0xDFFF)),
          );
        }
      }
    },
  );

  test('larger type and wider line spacing use more pages', () {
    final text = formatChapter(
      List.filled(30, '同样的文字应当使用同样的测量和绘制样式。').join('\n'),
    );
    final normal = paginateChapter(
      text,
      const Size(300, 500),
      const ReadingStyle(),
    );
    final large = paginateChapter(
      text,
      const Size(300, 500),
      const ReadingStyle(fontSize: 27, lineHeight: 2),
    );
    expect(large.length, greaterThan(normal.length));
  });

  test(
    'old page position follows the same text after paragraph formatting',
    () {
      expect(remapTextOffset('甲乙\n丙丁', 3, '　　甲乙\n\n　　丙丁'), 8);
    },
  );
}
