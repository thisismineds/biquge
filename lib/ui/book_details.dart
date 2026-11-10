import 'package:flutter/material.dart';

import '../entity/BookInfo.dart';
import '../reader/reader_screen.dart';
import '../storage/app_store.dart';
import 'book_cover.dart';

class BookDetails extends StatefulWidget {
  final AppStore store;
  final BookInfo book;
  const BookDetails({super.key, required this.store, required this.book});
  @override
  State<BookDetails> createState() => _BookDetailsState();
}

class _BookDetailsState extends State<BookDetails> {
  bool downloading = false;
  int cached = 0, total = 0;
  String? message;
  AppStore get store => widget.store;
  BookInfo get book => widget.book;

  Future<void> read({bool latest = false}) async {
    await store.add(book);
    if (!mounted) return;
    int? chapter;
    if (latest) {
      try {
        chapter = (await store.loadChapters(book)).length - 1;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
        return;
      }
    }
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              ReaderScreen(store: store, book: book, chapterIndex: chapter),
        ),
      );
    }
  }

  Future<void> download() async {
    if (downloading) {
      setState(() {
        downloading = false;
      });
      return;
    }
    setState(() {
      downloading = true;
      message = null;
    });
    try {
      await store.add(book);
      final chapters = await store.loadChapters(book);
      total = chapters.length;
      cached = 0;
      for (final c in chapters) {
        if (!mounted || !downloading) break;
        await store.loadContent(book, c.id);
        cached++;
        if (mounted) setState(() {});
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (mounted) {
        setState(() {
          message = cached == total ? '已缓存全部章节。' : '缓存已暂停，已下载的章节会保留。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = '已下载的章节会保留。$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          downloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍详情'),
        actions: [
          IconButton(
            tooltip: downloading ? '暂停缓存' : '离线缓存',
            onPressed: download,
            icon: Icon(
              downloading
                  ? Icons.pause_circle_outline
                  : Icons.download_outlined,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BookCover(
                title: book.Name,
                url: book.Img,
                width: 104,
                height: 148,
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.Name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      book.Author,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      [
                        book.CName,
                        book.BookStatus,
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      store.sourceName(book.sourceId),
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text('关于这本书', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            book.Desc.isEmpty ? '这本书暂时没有简介。' : book.Desc,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('最新章节'),
            subtitle: Text(
              [
                book.LastChapter,
                book.LastTime,
              ].where((s) => s.isNotEmpty).join('\n'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => read(latest: true),
          ),
          if (downloading) ...[
            const SizedBox(height: 20),
            LinearProgressIndicator(value: total == 0 ? null : cached / total),
            const SizedBox(height: 8),
            Text('已缓存 $cached / $total 章'),
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(message!),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: store.contains(book)
                      ? null
                      : () async {
                          await store.add(book);
                          if (mounted) setState(() {});
                        },
                  child: Text(store.contains(book) ? '已在书架' : '加入书架'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => read(),
                  child: const Text('开始阅读'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
