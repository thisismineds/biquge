import 'package:flutter/material.dart';

import '../entity/BookInfo.dart';
import '../service/book_sources.dart';
import '../storage/app_store.dart';
import 'book_cover.dart';
import 'book_details.dart';

class SearchScreen extends StatefulWidget {
  final AppStore store;
  const SearchScreen({super.key, required this.store});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final input = TextEditingController();
  List<Map<String, dynamic>> results = [];
  bool loading = false, hasMore = false;
  String? error, opening;
  String query = '';
  int page = 1, generation = 0;
  AppStore get store => widget.store;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> search({bool more = false}) async {
    if (more && loading) return;
    final key = more ? query : input.text.trim();
    if (key.isEmpty) return;
    final ticket = ++generation, next = more ? page + 1 : 1;
    final source = store.sourceId;
    setState(() {
      loading = true;
      error = null;
      query = key;
      if (!more) results = [];
    });
    try {
      final found = await store.sources.search(source, key, next);
      if (!mounted || ticket != generation) return;
      setState(() {
        results.addAll(found);
        page = next;
        hasMore = found.isNotEmpty && source != 'bqg631';
      });
      final history = store.preferences.getStringList('search.queries') ?? [];
      await store.preferences.setStringList(
        'search.queries',
        [key, ...history.where((q) => q != key)].take(8).toList(),
      );
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (mounted && ticket == generation) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> open(Map<String, dynamic> item) async {
    if (opening != null) return;
    setState(() {
      opening = item['Id'] as String;
    });
    try {
      final data = await store.sources.detail(
        item['sourceId'] as String,
        int.parse(item['Id'] as String),
      );
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                BookDetails(store: store, book: BookInfo.fromJson(data)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          opening = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('找一本好书')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            child: TextField(
              controller: input,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => search(),
              decoration: InputDecoration(
                hintText: '输入书名或作者',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '开始搜索',
                  onPressed: () {
                    FocusScope.of(context).unfocus();
                    search();
                  },
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Text(
                  '当前书源',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: store.sourceId,
                      isExpanded: true,
                      items: BookSources.sources
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.id,
                              child: Text(s.name),
                            ),
                          )
                          .toList(),
                      onChanged: (id) async {
                        if (id == null) return;
                        await store.selectSource(id);
                        if (!mounted) return;
                        setState(() {});
                        if (input.text.trim().isNotEmpty) search();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: query.isEmpty
                ? _history(context)
                : error != null && results.isEmpty
                ? _message(error!, retry: true)
                : results.isEmpty && !loading
                ? _message('暂时没有找到这本书，换个书源再试试。')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    itemCount: results.length + (hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 32),
                    itemBuilder: (context, i) {
                      if (i == results.length) {
                        return Center(
                          child: TextButton(
                            onPressed: loading
                                ? null
                                : () => search(more: true),
                            child: const Text('加载更多'),
                          ),
                        );
                      }
                      final b = results[i];
                      return InkWell(
                        onTap: () => open(b),
                        borderRadius: BorderRadius.circular(8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            BookCover(
                              title: b['Name'] as String,
                              url: b['Img'] as String? ?? '',
                              width: 70,
                              height: 100,
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    b['Name'] as String,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    b['Author'] as String? ?? '',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    b['Desc'] as String? ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.6,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (opening == b['Id'])
                              const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (error != null && results.isNotEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
        ],
      ),
    );
  }

  Widget _history(BuildContext context) {
    final history = store.preferences.getStringList('search.queries') ?? [];
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (history.isEmpty)
              Text(
                '从一个书名，走进另一个世界。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            if (history.isNotEmpty) ...[
              Text('最近搜索', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: history
                    .map(
                      (q) => ActionChip(
                        label: Text(q),
                        onPressed: () {
                          input.text = q;
                          search();
                        },
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _message(String text, {bool retry = false}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (retry) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => search(),
              child: const Text('重新搜索'),
            ),
          ],
        ],
      ),
    ),
  );
}
