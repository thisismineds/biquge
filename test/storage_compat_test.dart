import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingyue/entity/BookInfo.dart';
import 'package:qingyue/storage/app_store.dart';

void main() {
  test('old volume headings are not treated as readable chapters', () async {
    final oldToc = [
      {'hasContent': 0, 'id': 0, 'name': '第一卷'},
      {'hasContent': 2, 'id': 7, 'name': '第一章'},
      {'hasContent': 0, 'id': 0, 'name': '第二卷'},
      {'hasContent': 2, 'id': 8, 'name': '第二章'},
    ];
    SharedPreferences.setMockInitialValues({'42chapters': jsonEncode(oldToc), '7': '旧缓存第一章', '8': '旧缓存第二章'});
    final store = AppStore(await SharedPreferences.getInstance());
    final book = BookInfo.id(42, '旧书');
    expect((await store.loadChapters(book)).map((c) => c.id), [7, 8]);
    expect(await store.loadContent(book, 8), '旧缓存第二章');
    expect(store.preferences.getString('42chapters'), jsonEncode(oldToc));
  });
}
