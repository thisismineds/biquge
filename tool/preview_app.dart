// Development-only preview entry. Uses in-memory illustrative data, never a user's shelf.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/main.dart';
import 'package:qingyue/entity/Book.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/entity/BookTag.dart';
import 'package:qingyue/entity/Chapter.dart';
import 'package:qingyue/storage/app_store.dart';

const previewText = '''雨停以后，街角的书店重新开了门。檐下的水珠落在石阶上，风从半开的木窗里穿过，带来淡淡的纸张气息。
林川在靠窗的位置坐下，翻开昨晚没有读完的那一页。窗外有人撑伞走过，屋里却安静得只剩下翻书的声音。
故事并不急着给出答案。他把书签往后挪了一点，决定再读一章。
远处的山色渐渐清晰，像一封终于展开的来信。那些曾经模糊的字句，也在午后的光里慢慢有了轮廓。
他抬起头时，窗边的茶还温着。书页间夹着一片银杏叶，那是上个秋天留下的标记。
有些旅程不必急着赶路。只要再翻过一页，故事就会继续。''';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final names = ['山间来信', '长街灯未眠', '云海以南', '慢慢读完这一生', '远山有回声', '在人间等风'];
  final shelf = List.generate(
    names.length,
    (i) =>
        Book(
            7101,
            i == 0 ? '第一章 雨后的书店' : '',
            i == 2 ? 1 : 0,
            701 + i,
            names[i],
            i == 0 ? '林知远' : '预览示例',
            '',
            7102,
            '第二章 风从窗边来',
            '',
          )
          ..sourceId = i == 0
              ? 'legacy'
              : ['bqg631', 'kuwo', 'biquges123'][(i - 1) % 3],
  );
  final info = BookInfo.id(701, names.first)
    ..Author = '林知远'
    ..Desc = '用于展示阅读排版的原创示例文字。';
  final tag = BookTag(0, 0, [
    Chapter(2, 7101, '第一章 雨后的书店'),
    Chapter(2, 7102, '第二章 风从窗边来'),
  ], names.first)..content = previewText;
  // This development entry uses a disposable in-memory shelf.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'booklist': jsonEncode(shelf),
    '701': jsonEncode(tag),
    '701chapters': jsonEncode(tag.chapters),
    '7101': previewText,
    '7102': previewText,
    'info:701': jsonEncode(info),
  });
  final store = AppStore(await SharedPreferences.getInstance());
  runApp(ReaderApp(store: store));
}
