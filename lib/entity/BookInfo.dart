import 'Book.dart';

class BookInfo {
  String sourceId = 'legacy';
  String Author = '';
  String BookStatus = '';
  dynamic BookVote;
  int CId = 0;
  String CName = '';
  int Id = 0;
  String Name = '';
  String Img = '';
  String Desc = '';
  int LastChapterId = 0;
  String LastChapter = '';
  int FirstChapterId = 0;
  String LastTime = '';
  List<Book> SameUserBooks = [];

  BookInfo.id(this.Id, this.Name);
  BookInfo.name(this.CId, this.Name);
  BookInfo(
      this.Author,
      this.BookStatus,
      this.BookVote,
      this.CId,
      this.CName,
      this.Id,
      this.Name,
      this.Img,
      this.Desc,
      this.LastChapterId,
      this.LastChapter,
      this.FirstChapterId,
      this.LastTime,
      this.SameUserBooks);

  factory BookInfo.fromJson(Map<String, dynamic> json) => BookInfo(
        json['Author'] as String? ?? '',
        json['BookStatus'] as String? ?? '',
        json['BookVote'],
        json['CId'] as int? ?? 0,
        json['CName'] as String? ?? '',
        json['Id'] as int? ?? 0,
        json['Name'] as String? ?? '',
        json['Img'] as String? ?? '',
        json['Desc'] as String? ?? '',
        json['LastChapterId'] as int? ?? 0,
        json['LastChapter'] as String? ?? '',
        json['FirstChapterId'] as int? ?? 0,
        json['LastTime'] as String? ?? '',
        (json['SameUserBooks'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(Book.fromJson)
            .toList(),
      )..sourceId = json['sourceId'] as String? ?? 'legacy';

  Map<String, dynamic> toJson() => {
        'Author': Author,
        'BookStatus': BookStatus,
        'BookVote': BookVote,
        'CId': CId,
        'CName': CName,
        'Id': Id,
        'Name': Name,
        'Img': Img,
        'Desc': Desc,
        'LastChapterId': LastChapterId,
        'LastChapter': LastChapter,
        'FirstChapterId': FirstChapterId,
        'LastTime': LastTime,
        'SameUserBooks': SameUserBooks.map((book) => book.toJson()).toList(),
        'sourceId': sourceId,
      };
}
