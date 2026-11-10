import 'dart:async';
import 'dart:convert';

import 'package:PureBook/common/ReaderPageAgent.dart';
import 'package:PureBook/common/toast.dart';
import 'package:PureBook/entity/BookInfo.dart';
import 'package:PureBook/entity/BookTag.dart';
import 'package:PureBook/entity/Chapter.dart';
import 'package:PureBook/service/book_sources.dart';
import 'package:PureBook/event/event.dart';
import 'package:PureBook/model/ColorModel.dart';
import 'package:PureBook/store/Store.dart';
import 'package:PureBook/view/BookDetail.dart';
import 'package:PureBook/view/ChapterView.dart';
import 'package:PureBook/view/MyBottomSheet.dart';
import 'package:PureBook/view/MyViewPage.dart';
import 'package:flustars/flustars.dart';
import 'package:flutter/material.dart';

import '../common/Screen.dart';

class ReadBook extends StatefulWidget {
  BookInfo _bookInfo;

  ReadBook(this._bookInfo);

  @override
  State<StatefulWidget> createState() {
    // TODO: implement createState
    return _ReadBookState(_bookInfo);
  }
}

class _ReadBookState extends State<ReadBook> with WidgetsBindingObserver {
  BookInfo _bookInfo;
  BookTag _bookTag;
  final GlobalKey<ScaffoldState> _globalKey = GlobalKey<ScaffoldState>();
  String content = '';
  double contentH;
  double contentW;
  double fontSize = 27.0;
  MyPageController _pageController;
  bool showMenu = false;
  List<List> bgs = [
    [246, 242, 234],
    [242, 233, 209],
    [231, 241, 231],
    [228, 239, 242],
    [242, 228, 228],
  ];

  int bg_i = 0;

  _ReadBookState(this._bookInfo);

  List<Chapter> chapters = [];
  var value;
  bool loading = false;
  bool initialized = false;
  bool downloading = false;
  String error;
  StreamSubscription<ChapterEvent> chapterSubscription;
  StreamSubscription<PageEvent> pageSubscription;
  String get recordKey =>
      BookSources.recordKey(_bookInfo.sourceId, _bookInfo.Id);
  String get chaptersKey => _bookInfo.sourceId == 'legacy'
      ? '${_bookInfo.Id}chapters'
      : '$recordKey:chapters';
  String contentKey(int id) =>
      BookSources.contentKey(_bookInfo.sourceId, _bookInfo.Id, id);

  @override
  void dispose() {
    // TODO: implement dispose
    chapterSubscription?.cancel();
    pageSubscription?.cancel();
    _pageController?.dispose();
    super.dispose();
    if (_bookTag != null && !loading && error == null)
      SpUtil.putString(recordKey, jsonEncode(_bookTag));
    SpUtil.putDouble('fontSize', fontSize);
    SpUtil.putInt('bg_i', bg_i);

    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_bookTag != null && !loading && error == null)
      SpUtil.putString(recordKey, jsonEncode(_bookTag));
    SpUtil.putDouble('fontSize', fontSize);
  }

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    chapterSubscription = eventBus
        .on<ChapterEvent>()
        .listen((ChapterEvent data) => freshUi(data.chapterId));
    pageSubscription = eventBus
        .on<PageEvent>()
        .listen((PageEvent data) => _changePage(data.page));
    getBookRecord();
    if (SpUtil.haveKey('fontSize')) {
      fontSize = SpUtil.getDouble('fontSize');
    }
    if (SpUtil.haveKey('bg_i')) {
      bg_i = SpUtil.getInt('bg_i');
    }
    var widgetsBinding = WidgetsBinding.instance;
    widgetsBinding.addPostFrameCallback((callback) {
      asyncInit();
      value = _bookTag.cur.toDouble();
      contentH = ScreenUtil.getScreenH(context) -
          ScreenUtil.getStatusBarH(context) -
          30 -
          60;
      contentW = ScreenUtil.getScreenW(context) - 20;
    });
  }

  Future<void> asyncInit() async {
    try {
      await getChapters();
      await loadChapter(1);
      if (mounted)
        setState(() {
          initialized = true;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = '$e';
        });
    }
  }

  freshUi(int cur) {
    if (loading) return;
    if (mounted) {
      setState(() {
        value = cur.toDouble();
        _bookTag.cur = cur;
        _bookTag.index = 0;
        loadChapter(1);
      });
    }
  }

//获取本书记录
  void getBookRecord() {
    if (SpUtil.haveKey(recordKey)) {
      _bookTag = BookTag.fromJson(jsonDecode(SpUtil.getString(recordKey)));
      chapters = _bookTag.chapters ?? [];
      _bookTag.pageOffsets ??= [];
      if (_bookTag.cur == null ||
          _bookTag.cur < 0 ||
          _bookTag.cur >= chapters.length) _bookTag.cur = 0;
      if (_bookTag.index == null ||
          _bookTag.index < 0 ||
          _bookTag.index >= _bookTag.pageOffsets.length) _bookTag.index = 0;
    } else {
      if (SpUtil.haveKey(chaptersKey)) {
        chapters = (jsonDecode(SpUtil.getString(chaptersKey)) as List)
            .map((c) => Chapter.fromJson(c))
            .toList();
      }
      _bookTag = BookTag(0, 0, chapters, _bookInfo.Name);
    }
    value = _bookTag.cur.toDouble();
    _pageController = MyPageController(initialPage: _bookTag.index);
  }

  Future<void> getChapters() async {
    if (_bookInfo.sourceId == 'legacy') {
      if (chapters.isEmpty) throw SourceException('旧版书源已失效，请在新书源中重新搜索。');
      return;
    }
    try {
      final currentId = chapters.isNotEmpty ? chapters[_bookTag.cur].id : null;
      final data =
          await BookSources.instance.chapters(_bookInfo.sourceId, _bookInfo.Id);
      if (!mounted) return;
      chapters = data.map((c) {
        final chapter = Chapter.fromJson(c);
        if (SpUtil.haveKey(contentKey(chapter.id))) chapter.hasContent = 2;
        return chapter;
      }).toList();
      _bookTag.chapters = chapters;
      final restored = chapters.indexWhere((c) => c.id == currentId);
      _bookTag.cur = _bookInfo.CId == -1
          ? chapters.length - 1
          : restored < 0
              ? 0
              : restored;
      if (_bookInfo.CId == -1 || restored < 0) _bookTag.index = 0;
      value = _bookTag.cur.toDouble();
      SpUtil.putString(chaptersKey, jsonEncode(chapters));
    } catch (_) {
      if (chapters.isEmpty) rethrow;
    }
  }

  Future<void> loadChapter(int flag) async {
    await getBookChapter(1, flag == 1 ? 1 : 0);
    if (mounted) value = _bookTag.cur.toDouble();
  }

  Future<void> getBookChapter(int f, int g) async {
    if (loading || !mounted || chapters.isEmpty) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      while (chapters[_bookTag.cur].hasContent == 0) {
        final next = _bookTag.cur + (g == 1 ? 1 : -1);
        if (next < 0 || next >= chapters.length) return;
        _bookTag.cur = next;
      }
      final c = chapters[_bookTag.cur];
      final key = contentKey(c.id);
      final text = SpUtil.haveKey(key)
          ? SpUtil.getString(key)
          : await BookSources.instance
              .content(_bookInfo.sourceId, _bookInfo.Id, c.id);
      if (!mounted) return;
      final offsets =
          ReaderPageAgent.getPageOffsets(text, contentH, contentW, fontSize);
      if (offsets.isEmpty) throw SourceException('这一章没有可显示的正文。');
      await SpUtil.putString(key, text);
      _bookTag.content = text;
      _bookTag.pageOffsets = offsets;
      c.hasContent = 2;
      if (g == 0) {
        _bookTag.index = offsets.length - 1;
      }
      _bookTag.index = _bookTag.index.clamp(0, offsets.length - 1).toInt();
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_bookTag.index);
      } else {
        _pageController.dispose();
        _pageController = MyPageController(initialPage: _bookTag.index);
      }
      SpUtil.putString(recordKey, jsonEncode(_bookTag));
    } catch (e) {
      if (mounted)
        setState(() {
          error = '$e';
        });
    } finally {
      if (mounted)
        setState(() {
          loading = false;
        });
    }
  }

  Future<void> justDown(int start, int end) async {
    if (downloading) return;
    downloading = true;
    try {
      for (var i = start; i < end && mounted; i++) {
        final c = chapters[i];
        if (c.hasContent == 0) continue;
        final key = contentKey(c.id);
        if (!SpUtil.haveKey(key)) {
          final text = await BookSources.instance
              .content(_bookInfo.sourceId, _bookInfo.Id, c.id);
          await SpUtil.putString(key, text);
          await Future<void>.delayed(Duration(milliseconds: 500));
        }
        c.hasContent = 2;
      }
      if (mounted) Toast.show('缓存完成');
    } catch (e) {
      if (mounted) Toast.show('缓存已保留。$e');
    } finally {
      SpUtil.putString(chaptersKey, jsonEncode(chapters));
      downloading = false;
    }
  }

//prepage
  prePage() {
    if (loading) return;
    var temp = _bookTag.index - 1;
    if (temp >= 0) {
      _bookTag.index = temp;
      _pageController.jumpToPage(_bookTag.index);
    } else {
      int temp = _bookTag.cur - 1;
      if (temp < 0) {
        Toast.show('已经是第一页');
      } else {
        _bookTag.cur -= 1;
        loadChapter(0);
      }
    }
  }

  //nextpage
  nextPage() {
    if (loading) return;
    var temp = _bookTag.index + 1;
    if (temp < _bookTag.pageOffsets.length) {
      _bookTag.index = temp;
      _pageController.jumpToPage(_bookTag.index);
    } else {
      int t = _bookTag.cur + 1;
      if (t == chapters.length) {
//        Toast.show('已经是最后一页。。。。。。。。。。。。。');
      } else {
        _bookTag.cur += 1;
        _bookTag.index = 0;
        loadChapter(1);
      }
    }
    setState(() {});
  }

//上一章 下一章
  void changePage(BuildContext context, TapDownDetails details) {
    var wid = MediaQuery.of(context).size.width;
    var space = wid / 3;
    var curWid = details.localPosition.dx;
    setState(() {
      if (curWid > 0 && curWid < space) {
        prePage();
      } else if (curWid > space && curWid < 2 * space) {
        //弹出底部栏
        myshowModalBottomSheet(
          context: context,
          elevation: 0,
          builder: (BuildContext bc) {
            return StatefulBuilder(
              builder: (context, state) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        SizedBox(
                          width: 1,
                        ),
                        InkWell(
                          child: Container(
                            alignment: Alignment.center,
                            height: 50,
                            child: Text(
                              "上一章",
                              maxLines: 1,
                              style: TextStyle(color: Colors.blue),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          onTap: () {
                            _bookTag.index = 0;
                            _bookTag.cur -= 1;
                            loadChapter(0);
                          },
                        ),
                        Slider(
                          value: value,
                          max: (chapters.length - 1).toDouble(),
                          min: 0.0,
                          onChanged: (newValue) {
                            int temp = newValue.round();
                            _bookTag.cur = temp;
                            loadChapter(1);

                            state(() {
                              ///为了区分把setState改个名字
                              value = _bookTag.cur.toDouble();
                            });
                          },
                          label: '${chapters[_bookTag.cur].name} ',
                          divisions: chapters.length,
                          semanticFormatterCallback: (newValue) {
                            return '${newValue.round()} dollars';
                          },
                        ),
                        InkWell(
                          child: Container(
                            alignment: Alignment.center,
                            height: 50,
                            child: Text(
                              "下一章",
                              maxLines: 1,
                              style: TextStyle(color: Colors.blue),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          onTap: () {
                            _bookTag.cur =
                                (_bookTag.cur + 1) <= chapters.length - 1
                                    ? (_bookTag.cur + 1)
                                    : chapters.length - 1;
                            _bookTag.index = 0;
                            loadChapter(1);
                          },
                        ),
                        SizedBox(
                          width: 1,
                        ),
                      ],
                    ),
                    Table(children: <TableRow>[
                      TableRow(
                        children: <Widget>[
                          TableCell(
                            child: Center(
                              child: InkWell(
                                child: Container(
                                  alignment: Alignment.center,
                                  height: 50,
                                  child: Text(
                                    "目录",
                                    maxLines: 1,
                                    style: TextStyle(color: Colors.blue),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  _globalKey.currentState.openDrawer();
                                },
                              ),
                            ),
                          ),
                          TableCell(
                            child: Center(
                              child: InkWell(
                                child: Container(
                                  alignment: Alignment.center,
                                  height: 50,
                                  child: Text(
                                    "缓存",
                                    maxLines: 1,
                                    style: TextStyle(color: Colors.blue),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onTap: () {
                                  myshowModalBottomSheet(
                                      context: context,
                                      builder: (BuildContext bc) {
                                        return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: <Widget>[
                                              InkWell(
                                                child: Container(
                                                  alignment: Alignment.center,
                                                  height: 50,
                                                  child: Text(
                                                    "从当前章节缓存",
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                        color: Colors.blue),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                onTap: () {
                                                  justDown(_bookTag.cur,
                                                      chapters.length);
                                                  Navigator.pop(context);
                                                },
                                              ),
                                              InkWell(
                                                child: Container(
                                                  alignment: Alignment.center,
                                                  height: 50,
                                                  child: Text(
                                                    "全本缓存",
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                        color: Colors.blue),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                onTap: () {
                                                  justDown(0, chapters.length);
                                                  Navigator.pop(context);
                                                },
                                              ),
                                            ]);
                                      });
                                },
                              ),
                            ),
                          ),
                          TableCell(
                            child: Center(
                              child: InkWell(
                                child: Container(
                                  alignment: Alignment.center,
                                  height: 50,
                                  child: Text(
                                    "设置",
                                    maxLines: 1,
                                    style: TextStyle(color: Colors.blue),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onTap: () {
                                  Future<void> future = myshowModalBottomSheet(
                                      context: context,
                                      builder: (BuildContext bc) {
                                        return Column(
                                          textBaseline: TextBaseline.alphabetic,
                                          children: <Widget>[
                                            Table(children: <TableRow>[
                                              TableRow(
                                                children: <Widget>[
                                                  TableCell(
                                                    child: Center(
                                                      child: IconButton(
                                                        icon:
                                                            Icon(Icons.remove),
                                                        onPressed: () async {
                                                          state(() {
                                                            ///为了区分把setState改个名字
                                                            fontSize -= 1;
                                                          });
                                                          setState(() {
                                                            _bookTag.index = 0;
                                                            _bookTag.pageOffsets =
                                                                ReaderPageAgent
                                                                    .getPageOffsets(
                                                                        _bookTag
                                                                            .content,
                                                                        contentH,
                                                                        contentW,
                                                                        fontSize);
                                                          });
//                              changeCachePages();
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                  TableCell(
                                                    child: Center(
                                                      child: IconButton(
                                                        icon: Icon(Icons.add),
                                                        onPressed: () async {
                                                          state(() {
                                                            ///为了区分把setState改个名字
                                                            fontSize += 1;
                                                            setState(() {
                                                              _bookTag.index =
                                                                  0;
                                                              _bookTag.pageOffsets =
                                                                  ReaderPageAgent.getPageOffsets(
                                                                      _bookTag
                                                                          .content,
                                                                      contentH,
                                                                      contentW,
                                                                      fontSize);
                                                            });
                                                          });
//                              changeCachePages();
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ]),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceAround,
                                              children: readThemes(),
                                            )
                                          ],
                                          mainAxisSize: MainAxisSize.min,
                                        );
                                      });
                                  future.then((void value) async {
                                    reCalcPages();
                                  });
                                },
                              ),
                            ),
                          ),
                          TableCell(
                            child: Center(
                              child: InkWell(
                                child: Container(
                                  alignment: Alignment.center,
                                  height: 50,
                                  child: Text(
                                    "详情",
                                    maxLines: 1,
                                    style: TextStyle(color: Colors.blue),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onTap: () async {
                                  try {
                                    final data = await BookSources.instance
                                        .detail(
                                            _bookInfo.sourceId, _bookInfo.Id);
                                    final bookInfo = BookInfo.fromJson(data);
                                    if (!mounted) return;
                                    Navigator.of(context).push(
                                        new MaterialPageRoute(
                                            builder: (BuildContext context) =>
                                                BookDetail(bookInfo)));
                                  } catch (e) {
                                    if (mounted) Toast.show('$e');
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ]),
                    SizedBox(
                      height: 8,
                    )
                  ],
                );
              },
            );
          },
        );
      } else {
        nextPage();
      }
    });
  }

  void reCalcPages() {
    if (_bookTag.content == null) return;
    _bookTag.pageOffsets = ReaderPageAgent.getPageOffsets(
        _bookTag.content, contentH, contentW, fontSize);
    _bookTag.index =
        _bookTag.index.clamp(0, _bookTag.pageOffsets.length - 1).toInt();
    if (_pageController.hasClients) _pageController.jumpToPage(_bookTag.index);
    if (mounted) setState(() {});
  }

  List<Widget> readThemes() {
    List<Widget> wds = [];
    for (var i = 0; i < bgs.length; i++) {
      var f = bgs[i];
      wds.add(RawMaterialButton(
        onPressed: () {
          bg_i = i;
          if (mounted) {
            setState(() {});
          }
        },
        constraints: BoxConstraints(minWidth: 60.0, minHeight: 50.0),
        child: Container(
          margin: EdgeInsets.only(top: 5.0, bottom: 5.0),
          width: 40.0,
          height: 40.0,
          decoration: BoxDecoration(
              color: Color.fromRGBO(f[0], f[1], f[2], 1),
              borderRadius: BorderRadius.all(Radius.circular(25.0)),
              border: Border.all(color: Colors.white)),
        ),
      ));
    }
    wds.add(SizedBox(
      height: 8,
    ));
    return wds;
  }

  @override
  Widget build(BuildContext context) {
    if (error != null)
      return Scaffold(
          appBar: AppBar(title: Text(_bookInfo.Name)),
          body: Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(error),
                    FlatButton(
                        onPressed: () {
                          setState(() {
                            error = null;
                          });
                          asyncInit();
                        },
                        child: Text('重试'))
                  ]))));
    if (!initialized || chapters.isEmpty || _bookTag.content == null)
      return Scaffold(
          appBar: AppBar(title: Text(_bookInfo.Name)),
          body: Center(child: CircularProgressIndicator()));
    // TODO: implement build
    return Scaffold(
      key: _globalKey,
      backgroundColor: Store.value<ColorModel>(context).dark
          ? Color.fromRGBO(38, 38, 38, 1)
          : Color.fromRGBO(bgs[bg_i][0], bgs[bg_i][1], bgs[bg_i][2], 1),
      drawer: Drawer(
        child: ChapterView(
            chapters, _bookInfo.Id.toString(), _bookTag.cur, _bookInfo.Name),
      ),
      body: Stack(
        children: <Widget>[
          Container(
            child: MyPageView.builder(
              controller: _pageController,
              physics: AlwaysScrollableScrollPhysics(),
              itemBuilder: (BuildContext context, int index) {
                return _getContent()[index];
              },
              //条目个数
              itemCount: _bookTag.pageOffsets.length,
              onPageChanged: (i) {
                if (!loading) {
                  _bookTag.index = i;
                  setState(() {});
                }
              },
            ),
            padding: EdgeInsets.only(
                bottom: 25, top: ScreenUtil.getStatusBarH(context) + 30),
          ),
          Container(
            padding: EdgeInsets.only(
                left: 10,
                right: 10,
                bottom: 1,
                top: ScreenUtil.getStatusBarH(context)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  chapters.length > 0 ? chapters[_bookTag.cur].name : '',
                  style: TextStyle(fontSize: 16),
                ),
                Expanded(child: Container()),
                Row(
                  children: <Widget>[
                    Expanded(child: Container()),
                    Text(
                      _bookTag.pageOffsets == null
                          ? ''
                          : '第${_bookTag.index + 1}/${_bookTag.pageOffsets.length}页',
                      style: TextStyle(fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _getContent() {
    List<Widget> contents = [];
    for (var i = 0; i < _bookTag.pageOffsets.length; i++) {
      var content = _bookTag.stringAtPageIndex(i);
      if (content.startsWith('\n') || content.startsWith('\r\n')) {
        content = content.substring(1).trim();
      }
      if (content.startsWith('\r\n')) {
        content = content.substring(2).trim();
      }

      contents.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) {
            changePage(context, details);
          },
          child: Container(
              padding: EdgeInsets.only(
                right: 10,
                left: 10,
              ),
              height: double.infinity,
              width: double.infinity,
              child: Text(
                content,
                style: TextStyle(
                  fontSize: fontSize / Screen.textScaleFactor,
                ),
              )),
        ),
      );
    }

    return contents;
  }

  _changePage(int page) {
    if (loading) return;
    if (page > 0) {
      nextPage();
    } else {
      prePage();
    }
  }
}
