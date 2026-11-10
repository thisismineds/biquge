import 'dart:math' as math;

import 'package:flutter/material.dart';

class ReadingStyle {
  static const locale = Locale('zh', 'CN');
  static const textHeightBehavior = TextHeightBehavior(
    leadingDistribution: TextLeadingDistribution.even,
  );
  final double fontSize, lineHeight, paragraphGap, horizontalPadding;
  final String? fontFamily;
  const ReadingStyle({
    this.fontSize = 21,
    this.lineHeight = 1.75,
    this.paragraphGap = 12,
    this.horizontalPadding = 24,
    this.fontFamily,
  });

  TextStyle textStyle(Color color) => TextStyle(
    inherit: false,
    fontSize: fontSize,
    fontWeight: FontWeight.w400,
    height: lineHeight,
    letterSpacing: .15,
    fontFamily: fontFamily,
    color: color,
  );
  StrutStyle get strut => StrutStyle(
    fontSize: fontSize,
    height: lineHeight,
    fontFamily: fontFamily,
    fontWeight: FontWeight.w400,
    leadingDistribution: TextLeadingDistribution.even,
    forceStrutHeight: false,
  );
  ReadingStyle copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphGap,
    double? horizontalPadding,
    String? fontFamily,
  }) => ReadingStyle(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    paragraphGap: paragraphGap ?? this.paragraphGap,
    horizontalPadding: horizontalPadding ?? this.horizontalPadding,
    fontFamily: fontFamily ?? this.fontFamily,
  );
}

String formatChapter(String raw) => raw
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll('&nbsp;', ' ')
    .split(RegExp(r'\n+'))
    .map((p) => p.replaceAll(RegExp(r'[\t \u00a0\u3000]+'), ' ').trim())
    .where((p) => p.isNotEmpty)
    .map((p) => '　　$p')
    .join('\n\n');

int remapTextOffset(String oldText, int oldOffset, String newText) {
  final whitespace = RegExp(r'\s|\u3000');
  final count = oldText
      .substring(0, oldOffset.clamp(0, oldText.length))
      .replaceAll(whitespace, '')
      .length;
  if (count == 0) return 0;
  var seen = 0;
  for (var i = 0; i < newText.length; i++) {
    if (!whitespace.hasMatch(newText[i])) seen++;
    if (seen >= count) {
      var offset = i + 1;
      while (offset < newText.length && whitespace.hasMatch(newText[offset])) {
        offset++;
      }
      return offset;
    }
  }
  return newText.length;
}

class ReadingFragment {
  final String text;
  final double height, gapBefore;
  const ReadingFragment(this.text, this.height, this.gapBefore);
}

class ReadingPage {
  final int start, end;
  final List<ReadingFragment> fragments;
  const ReadingPage(this.start, this.end, this.fragments);
  double get height =>
      fragments.fold(0, (sum, f) => sum + f.height + f.gapBefore);
}

List<ReadingPage> paginateChapter(
  String text,
  Size size,
  ReadingStyle style, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (text.isEmpty || size.width <= 0 || size.height <= 0) return [];
  double measure(String value) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style.textStyle(Colors.black)),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      strutStyle: style.strut,
      locale: ReadingStyle.locale,
      textHeightBehavior: ReadingStyle.textHeightBehavior,
    )..layout(maxWidth: size.width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  final pages = <ReadingPage>[];
  var fragments = <ReadingFragment>[], cursor = 0, pageStart = 0;
  var used = 0.0;
  void finish() {
    if (fragments.isEmpty) return;
    pages.add(ReadingPage(pageStart, cursor, List.unmodifiable(fragments)));
    fragments = [];
    used = 0;
    pageStart = cursor;
  }

  final paragraphs = text.split('\n\n');
  for (
    var paragraphIndex = 0;
    paragraphIndex < paragraphs.length;
    paragraphIndex++
  ) {
    final paragraph = paragraphs[paragraphIndex];
    final boundaries = <int>[0];
    for (final c in paragraph.characters) {
      boundaries.add(boundaries.last + c.length);
    }
    var start = 0;
    while (start < boundaries.length - 1) {
      final gap = start == 0 && fragments.isNotEmpty ? style.paragraphGap : 0.0;
      final available = size.height - used - gap;
      var low = start + 1, high = boundaries.length - 1, fit = start;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        final height = measure(
          paragraph.substring(boundaries[start], boundaries[mid]),
        );
        if (height <= available + .01) {
          fit = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      if (fit == start) {
        if (fragments.isNotEmpty) {
          finish();
          continue;
        }
        // A viewport smaller than one line still advances one grapheme.
        fit = math.min(start + 1, boundaries.length - 1);
      }
      final part = paragraph.substring(boundaries[start], boundaries[fit]);
      final height = measure(part);
      fragments.add(ReadingFragment(part, height, gap));
      used += height + gap;
      cursor += part.length;
      start = fit;
      if (start < boundaries.length - 1) finish();
    }
    if (paragraphIndex < paragraphs.length - 1) cursor += 2;
  }
  finish();
  return pages;
}

class ReadingPageView extends StatelessWidget {
  final ReadingPage page;
  final ReadingStyle style;
  final Color color;
  const ReadingPageView({
    super.key,
    required this.page,
    required this.style,
    required this.color,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: page.fragments
        .map(
          (f) => Padding(
            padding: EdgeInsets.only(top: f.gapBefore),
            child: RichText(
              text: TextSpan(text: f.text, style: style.textStyle(color)),
              strutStyle: style.strut,
              textScaler: MediaQuery.textScalerOf(context),
              textDirection: TextDirection.ltr,
              locale: ReadingStyle.locale,
              textHeightBehavior: ReadingStyle.textHeightBehavior,
              softWrap: true,
              textAlign: TextAlign.start,
            ),
          ),
        )
        .toList(),
  );
}
