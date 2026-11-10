import 'dart:convert';
import 'dart:io';

import 'package:qingyue/service/book_sources.dart';

/// Opt-in network check; outputs metadata and lengths, never chapter text.
Future<void> main() async {
  final service = BookSources();
  var failed = false;
  try {
    for (final source in BookSources.sources) {
      try {
        final books = await service.search(source.id, '三国', 1);
        if (books.isEmpty) throw StateError('没有搜索结果');
        final book = books.firstWhere(
          (b) => b['Name'] == '神话版三国',
          orElse: () => books.first,
        );
        final id = int.parse(book['Id']);
        final detail = await service.detail(source.id, id);
        final chapters = await service.chapters(source.id, id);
        final text = await service.content(source.id, id, chapters.first['id']);
        if (text.isEmpty) throw StateError('正文为空');
        stdout.writeln(
          jsonEncode({
            'source': source.id,
            'checkedAt': DateTime.now().toUtc().toIso8601String(),
            'searchResults': books.length,
            'book': detail['Name'],
            'author': detail['Author'],
            'chapters': chapters.length,
            'firstChapter': chapters.first['name'],
            'characters': text.length,
          }),
        );
      } catch (e) {
        failed = true;
        stdout.writeln(jsonEncode({'source': source.id, 'error': '$e'}));
      }
    }
  } finally {
    service.client.close(force: true);
  }
  if (failed) exitCode = 1;
}
