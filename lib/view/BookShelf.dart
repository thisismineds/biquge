import 'dart:async';
import 'dart:convert';
import 'package:flustars/flustars.dart';
import 'package:flutter/material.dart';
import '../common/common.dart';
import '../entity/Book.dart';
import '../entity/BookInfo.dart';
import '../event/event.dart';
import '../service/book_sources.dart';
import 'MySearchDelegate.dart';
import 'ReadBook.dart';
import 'Search.dart';

class BookShelf extends StatefulWidget {
  @override
  _BookShelfState createState() => _BookShelfState();
}

class _BookShelfState extends State<BookShelf>
    with AutomaticKeepAliveClientMixin {
  List<Book> shelf = [];
  StreamSubscription<BooksEvent> subscription;
  String error;

  @override
  void initState() {
    super.initState();
    final saved = SpUtil.getString(Common.listbookname);
    if (saved != null && saved.isNotEmpty) {
      shelf = (jsonDecode(saved) as List).map((b) => Book.fromJson(b)).toList();
    }
    subscription = eventBus.on<BooksEvent>().listen((e) {
      if (mounted)
        setState(() {
          shelf = List<Book>.from(e.books);
        });
    });
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    var failed = 0;
    for (final b in List<Book>.from(shelf)) {
      if (b.sourceId == 'legacy') continue;
      try {
        final info = await BookSources.instance.detail(b.sourceId, b.Id);
        final current =
            shelf.where((v) => v.Id == b.Id && v.sourceId == b.sourceId);
        if (current.isEmpty) continue;
        final item = current.first;
        item.NewChapterCount =
            info['LastChapter'] != item.LastChapter ? 1 : item.NewChapterCount;
        item.LastChapter = info['LastChapter'];
        item.LastChapterId = info['LastChapterId'];
        item.UpdateTime = info['LastTime'];
        await SpUtil.putString(
            'info:${BookSources.recordKey(b.sourceId, b.Id)}',
            jsonEncode(info));
      } catch (_) {
        failed++;
      }
    }
    await SpUtil.putString(Common.listbookname, jsonEncode(shelf));
    if (mounted)
      setState(() {
        error = failed == 0 ? null : '$failed 本书暂时无法更新，已保留原有记录。';
      });
  }

  void open(Book b) {
    final key = BookSources.recordKey(b.sourceId, b.Id);
    final saved = SpUtil.getString('info:$key');
    final info = saved != null && saved.isNotEmpty
        ? BookInfo.fromJson(jsonDecode(saved))
        : (BookInfo.id(b.Id, b.Name)..sourceId = b.sourceId);
    b.NewChapterCount = 0;
    SpUtil.putString(Common.listbookname, jsonEncode(shelf));
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReadBook(info)));
  }

  Future<void> remove(Book b) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text('移出书架'),
                content: Text('移出《${b.Name}》？已缓存正文和阅读进度会保留。'),
                actions: [
                  FlatButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('取消')),
                  FlatButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('移出'))
                ]));
    if (confirm != true || !mounted) return;
    setState(() {
      shelf.removeWhere((v) => v.Id == b.Id && v.sourceId == b.sourceId);
    });
    SpUtil.putString(Common.listbookname, jsonEncode(shelf));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
          title: Text('书架'),
          leading: IconButton(
              icon: Icon(Icons.menu),
              onPressed: () => eventBus.fire(OpenEvent(''))),
          actions: [
            IconButton(
                icon: Icon(Icons.search),
                tooltip: '搜索小说',
                onPressed: () => myshowSearch(
                    context: context, delegate: SearchBarDelegate()))
          ]),
      body: RefreshIndicator(
          onRefresh: refresh,
          child: ListView(physics: AlwaysScrollableScrollPhysics(), children: [
            if (error != null)
              Padding(padding: EdgeInsets.all(16), child: Text(error)),
            if (shelf.isEmpty)
              Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('书架还是空的，点击右上角搜索添加小说。')),
            ...shelf.map((b) => ListTile(
                leading: Image.network(BookSources.cover(b.Img),
                    width: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.book)),
                title:
                    Text('${b.Name}${b.NewChapterCount == 1 ? ' · 有更新' : ''}'),
                subtitle: Text(
                    '${b.sourceId == 'legacy' ? '旧版书源（仅缓存）' : BookSources.source(b.sourceId).name}\n${b.LastChapter ?? ''}'),
                isThreeLine: true,
                onTap: () => open(b),
                onLongPress: () => remove(b))),
          ])),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
