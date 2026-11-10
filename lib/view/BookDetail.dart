import 'dart:convert';
import 'package:flustars/flustars.dart';
import 'package:flutter/material.dart';
import '../common/common.dart';
import '../entity/Book.dart';
import '../entity/BookInfo.dart';
import '../entity/Chapter.dart';
import '../event/event.dart';
import '../service/book_sources.dart';
import 'ReadBook.dart';

class BookDetail extends StatefulWidget {
  final BookInfo book;
  BookDetail(this.book);
  @override
  _BookDetailState createState() => _BookDetailState();
}

class _BookDetailState extends State<BookDetail> {
  List<Book> shelf = [];
  bool downloading = false;
  String downloadStatus = '';
  BookInfo get book => widget.book;
  String get recordKey => BookSources.recordKey(book.sourceId, book.Id);
  int get shelfIndex =>
      shelf.indexWhere((b) => b.Id == book.Id && b.sourceId == book.sourceId);

  @override
  void initState() {
    super.initState();
    final saved = SpUtil.getString(Common.listbookname);
    if (saved != null && saved.isNotEmpty) {
      shelf = (jsonDecode(saved) as List).map((b) => Book.fromJson(b)).toList();
    }
    SpUtil.putString('info:$recordKey', jsonEncode(book));
  }

  void saveShelf() {
    SpUtil.putString(Common.listbookname, jsonEncode(shelf));
    eventBus.fire(BooksEvent(shelf));
  }

  void addToShelf() {
    if (shelfIndex >= 0) return;
    shelf.insert(
        0,
        Book(0, '', 0, book.Id, book.Name, book.Author, book.Img,
            book.LastChapterId, book.LastChapter, book.LastTime)
          ..sourceId = book.sourceId);
    saveShelf();
    setState(() {});
  }

  void read({bool latest = false}) {
    addToShelf();
    book.CId = latest ? -1 : 0;
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReadBook(book)));
  }

  Future<void> download() async {
    if (downloading) return;
    addToShelf();
    setState(() {
      downloading = true;
      downloadStatus = '正在获取目录…';
    });
    List<Chapter> chapters;
    try {
      final data = await BookSources.instance.chapters(book.sourceId, book.Id);
      chapters = data.map((c) => Chapter.fromJson(c)).toList();
      for (var i = 0; i < chapters.length; i++) {
        if (!mounted) break;
        final c = chapters[i];
        final key = BookSources.contentKey(book.sourceId, book.Id, c.id);
        if (!SpUtil.haveKey(key)) {
          final text =
              await BookSources.instance.content(book.sourceId, book.Id, c.id);
          await SpUtil.putString(key, text);
          // Keep bulk downloads sequential and avoid hammering a shared source.
          await Future<void>.delayed(Duration(milliseconds: 500));
        }
        c.hasContent = 2;
        if (mounted)
          setState(() {
            downloadStatus = '已缓存 ${i + 1}/${chapters.length} 章';
          });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          downloadStatus = '缓存已保留。$e';
        });
    } finally {
      if (chapters != null)
        await SpUtil.putString('$recordKey:chapters', jsonEncode(chapters));
      if (mounted)
        setState(() {
          downloading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(book.Name)),
        body: ListView(padding: EdgeInsets.all(16), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Image.network(BookSources.cover(book.Img),
                width: 84,
                height: 112,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    SizedBox(width: 84, height: 112, child: Icon(Icons.book))),
            SizedBox(width: 16),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(book.Name, style: TextStyle(fontSize: 20)),
                  SizedBox(height: 8),
                  Text('作者：${book.Author}'),
                  Text('分类：${book.CName}'),
                  Text('状态：${book.BookStatus}'),
                  Text('来源：${BookSources.source(book.sourceId).name}'),
                ])),
          ]),
          SizedBox(height: 24),
          Text('简介', style: TextStyle(fontSize: 18)),
          SizedBox(height: 8),
          Text(book.Desc),
          SizedBox(height: 16),
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('最新章节'),
              subtitle: Text('${book.LastChapter}\n${book.LastTime}'),
              trailing: Icon(Icons.chevron_right),
              onTap: () => read(latest: true)),
          if (downloadStatus.isNotEmpty) Text(downloadStatus),
          if (downloading) LinearProgressIndicator(),
        ]),
        bottomNavigationBar: SafeArea(
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
              FlatButton(
                  onPressed: () {
                    if (shelfIndex < 0) {
                      addToShelf();
                    } else {
                      setState(() {
                        shelf.removeAt(shelfIndex);
                      });
                      saveShelf();
                    }
                  },
                  child: Text(shelfIndex < 0 ? '加入书架' : '移出书架')),
              FlatButton(onPressed: () => read(), child: Text('开始阅读')),
              FlatButton(
                  onPressed: downloading ? null : download,
                  child: Text('离线缓存')),
            ])),
      );
}
