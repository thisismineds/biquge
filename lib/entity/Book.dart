import 'package:json_annotation/json_annotation.dart';
part 'Book.g.dart';

@JsonSerializable()
class Book {
  @JsonKey(ignore: true)
  String sourceId = 'legacy';

  int ChapterId;
  String ChapterName;
  int NewChapterCount;
  int Id;
  String Name;
  String Author;
  String Img;
  int LastChapterId;
  String LastChapter;
  String UpdateTime;

  factory Book.fromJson(Map<String, dynamic> json) =>
      _$BookFromJson(json)..sourceId = json['sourceId'] as String ?? 'legacy';

  Map<String, dynamic> toJson() => _$BookToJson(this)..['sourceId'] = sourceId;

  Book(
      this.ChapterId,
      this.ChapterName,
      this.NewChapterCount,
      this.Id,
      this.Name,
      this.Author,
      this.Img,
      this.LastChapterId,
      this.LastChapter,
      this.UpdateTime);

  @override
  String toString() {
    return 'Book{ChapterId: $ChapterId, ChapterName: $ChapterName, NewChapterCount: $NewChapterCount, Id: $Id, Name: $Name, Author: $Author, Img: $Img, LastChapterId: $LastChapterId, LastChapter: $LastChapter, UpdateTime: $UpdateTime}';
  }
}
