import 'package:flutter/material.dart';

import '../entity/BookInfo.dart';
import '../storage/app_store.dart';

class CacheManagement extends StatefulWidget {
  final AppStore store;
  const CacheManagement({super.key, required this.store});

  @override
  State<CacheManagement> createState() => _CacheManagementState();
}

class _CacheManagementState extends State<CacheManagement> {
  bool deleting = false;

  Future<void> clear(BookInfo book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本书缓存？'),
        content: Text('《${book.Name}》的已缓存正文将被删除，书架和阅读进度会保留。下次阅读需要联网重新缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除缓存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => deleting = true);
    try {
      await widget.store.clearCache(book);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('缓存已删除，书架和阅读进度已保留。')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('未能完成清理，请重试。$e')));
      }
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final books = widget.store.cachedBooks;
      return Scaffold(
        appBar: AppBar(title: const Text('缓存管理')),
        body: books.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '暂无缓存书籍\n阅读或下载后的章节会显示在这里。',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                itemCount: books.length + 1,
                separatorBuilder: (_, index) => index == 0
                    ? const SizedBox(height: 8)
                    : const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('按书清理已缓存正文，保留书架和阅读进度。'),
                    );
                  }
                  final book = books[index - 1];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(book.Name),
                    subtitle: Text(
                      '${widget.store.sourceName(book.sourceId)} · 已缓存 ${widget.store.cachedBookChapterCount(book)} 章',
                    ),
                    trailing: IconButton(
                      tooltip: '删除 ${book.Name} 的缓存',
                      onPressed: deleting ? null : () => clear(book),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  );
                },
              ),
      );
    },
  );
}
