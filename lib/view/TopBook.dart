import 'package:flustars/flustars.dart';
import 'package:flutter/material.dart';
import '../service/book_sources.dart';
import 'MySearchDelegate.dart';
import 'Search.dart';

class TopBook extends StatefulWidget {
  @override
  _TopBookState createState() => _TopBookState();
}

class _TopBookState extends State<TopBook> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('书源')),
        body: ListView(children: [
          Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择书源后搜索书名或作者。站点暂不可用时，可以换一个书源。')),
          ...BookSources.sources.map((source) => RadioListTile<String>(
              value: source.id,
              groupValue: BookSources.activeId,
              title: Text(source.name),
              subtitle: Text(source.url),
              onChanged: (id) {
                setState(() {
                  BookSources.activeId = id;
                });
                SpUtil.putString('activeSourceId', id);
              })),
          Padding(
              padding: EdgeInsets.all(16),
              child: RaisedButton(
                  child: Text('搜索小说'),
                  onPressed: () => myshowSearch(
                      context: context, delegate: SearchBarDelegate()))),
        ]),
      );
}
