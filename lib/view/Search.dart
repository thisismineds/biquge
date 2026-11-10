import 'package:PureBook/service/book_sources.dart';
import 'package:PureBook/entity/BookInfo.dart';
import 'package:PureBook/model/SearchModel.dart';
import 'package:PureBook/store/Store.dart';
import 'package:PureBook/view/MySearchDelegate.dart';
import 'package:flutter/material.dart';
import 'package:flustars/flustars.dart';

import 'BookDetail.dart';

class SearchBarDelegate extends MySearchDelegate<String> {
  @override
  ThemeData appBarTheme(BuildContext context) {
    // TODO: implement appBarTheme
    assert(context != null);
    final ThemeData theme = Theme.of(context);
    assert(theme != null);
    return theme.copyWith(
      primaryColor: Colors.black,
      primaryIconTheme: theme.primaryIconTheme.copyWith(color: Colors.grey),
      primaryColorBrightness: Brightness.light,
      primaryTextTheme: theme.textTheme,
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: Icon(
          Icons.clear,
          color: Colors.black,
        ),
        onPressed: () {
          query = "";
          showSuggestions(context);
        },
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: AnimatedIcon(
        icon: AnimatedIcons.menu_arrow,
        progress: transitionAnimation,
        color: Colors.black,
      ),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    var value = Store.value<SearchModel>(context);

    value.setHistory(query);
    return SearchResult(query);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.all(5.0),
        child: Column(
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: <Widget>[
                    FlatButton(
                      onPressed: null,
                      child: Text(
                        '搜索历史',
                        style: TextStyle(color: Colors.black),
                      ),
                    )
                  ],
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: <Widget>[
                    Store.connect<SearchModel>(
                        builder: (ctx, SearchModel data, child) {
                      return FlatButton(
                          onPressed: () {
                            data.clearHistory();
                          },
                          child: Text('清空历史'));
                    }),
                  ],
                ),
              ],
            ),
            Store.connect<SearchModel>(builder: (ctx, SearchModel data, child) {
              return Wrap(
                spacing: 2, //主轴上子控件的间距
                runSpacing: 5, //交叉轴上子控件之间的间距
                children: getHistory(data.getHistory(), context),
              );
            }),
          ],
        ));
  }

  getHistory(List<String> history, BuildContext context) {
    List<Widget> wds = [];
    for (var i = 0; i < history.length; i++) {
      wds.add(ActionChip(
        backgroundColor: Colors.white,
        label: Text(history[i]),
        onPressed: () {
          this.query = history[i];
        },
      ));
    }
    return wds;
  }
}

class SearchResult extends StatefulWidget {
  final String word;
  SearchResult(this.word);
  @override
  _SearchResultState createState() => _SearchResultState();
}

class _SearchResultState extends State<SearchResult> {
  String sourceId = BookSources.activeId;
  List<Map<String, dynamic>> items = [];
  int page = 1, generation = 0;
  bool loading = false, hasMore = true;
  String error;

  @override
  void initState() {
    super.initState();
    load(reset: true);
  }

  @override
  void didUpdateWidget(SearchResult oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.word != widget.word) load(reset: true);
  }

  Future<void> load({bool reset = false}) async {
    if (loading && !reset) return;
    final request = ++generation;
    final nextPage = reset ? 1 : page + 1;
    setState(() {
      loading = true;
      error = null;
      if (reset) items = [];
    });
    try {
      final data =
          await BookSources.instance.search(sourceId, widget.word, nextPage);
      if (!mounted || request != generation) return;
      setState(() {
        items.addAll(data);
        page = nextPage;
        hasMore = data.isNotEmpty && sourceId != 'bqg631';
      });
    } catch (e) {
      if (mounted && request == generation)
        setState(() {
          error = '$e';
        });
    } finally {
      if (mounted && request == generation)
        setState(() {
          loading = false;
        });
    }
  }

  Future<void> open(Map<String, dynamic> item) async {
    try {
      final data = await BookSources.instance
          .detail(item['sourceId'], int.parse(item['Id']));
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BookDetail(BookInfo.fromJson(data))));
    } catch (e) {
      if (mounted)
        showDialog(
            context: context,
            builder: (_) => AlertDialog(
                    title: Text('暂时无法打开'),
                    content: Text('$e'),
                    actions: [
                      FlatButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('确定'))
                    ]));
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Text('书源：'),
              Expanded(
                  child: DropdownButton<String>(
                      value: sourceId,
                      isExpanded: true,
                      items: BookSources.sources
                          .map((s) => DropdownMenuItem(
                              value: s.id, child: Text(s.name)))
                          .toList(),
                      onChanged: (id) {
                        setState(() {
                          sourceId = id;
                          BookSources.activeId = id;
                        });
                        SpUtil.putString('activeSourceId', id);
                        load(reset: true);
                      })),
            ])),
        if (loading) LinearProgressIndicator(),
        if (error != null)
          Padding(
              padding: EdgeInsets.all(16),
              child: Column(children: [
                Text(error),
                FlatButton(
                    onPressed: () => load(reset: items.isEmpty),
                    child: Text('重试'))
              ])),
        Expanded(
            child: items.isEmpty && !loading && error == null
                ? Center(child: Text('没有找到书籍，可以切换书源再试。'))
                : ListView.builder(
                    itemCount:
                        items.length + (hasMore && items.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == items.length)
                        return FlatButton(
                            onPressed: loading ? null : () => load(),
                            child: Text('加载更多'));
                      final b = items[i];
                      return ListTile(
                          leading: Image.network(b['Img'],
                              width: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(Icons.book)),
                          title: Text(b['Name']),
                          subtitle: Text('${b['Author']}\n${b['Desc']}',
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          isThreeLine: true,
                          onTap: () => open(b));
                    })),
      ]);
}
