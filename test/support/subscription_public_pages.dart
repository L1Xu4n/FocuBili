import 'dart:async';
import 'dart:convert';
import 'dart:io';

class PublicPages {
  PublicPages(int count) : videos = List.generate(count, (i) => video(i));
  static final old = DateTime.utc(2026, 1, 1);
  static Map<String, Object> video(int id, {DateTime? published}) => {
    'bvid': 'BV${id.toString().padLeft(10, '0')}',
    'title': '课程 $id：理解概念与练习',
    'duration': 60,
    'created':
        (published ?? old.subtract(Duration(seconds: id)))
            .millisecondsSinceEpoch ~/
        1000,
  };
  List<Map<String, Object>> videos;
  final calls = <Uri>[];
  int? failPage, repeatPage, wrongPage, holdPage;
  Completer<void>? held, entered;
  Future<String> call(Uri uri) async {
    calls.add(uri);
    if (uri.path.endsWith('/nav')) {
      return jsonEncode({
        'code': -101,
        'data': {
          'wbi_img': {
            'img_url':
                'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
            'sub_url':
                'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
          },
        },
      });
    }
    final collection = uri.path.endsWith('seasons_archives_list');
    final page = int.parse(
      uri.queryParameters[collection ? 'page_num' : 'pn']!,
    );
    if (page == holdPage) {
      if (entered?.isCompleted == false) entered!.complete();
      await held?.future;
    }
    if (page == failPage) throw const SocketException('offline fixture');
    final effective = page == repeatPage ? page - 1 : page;
    final ordered = collection && uri.queryParameters['sort_reverse'] == 'true'
        ? videos.reversed
        : videos;
    final rows = ordered.skip((effective - 1) * 20).take(20).toList();
    return jsonEncode({
      'code': 0,
      'data': collection
          ? {
              'page': {'page_num': page == wrongPage ? 1 : page},
              'meta': {'total': videos.length},
              'archives': rows,
            }
          : {
              'page': {
                'pn': page == wrongPage ? 1 : page,
                'count': videos.length,
              },
              'list': {'vlist': rows},
            },
    });
  }

  List<int> get pages => [
    for (final uri in calls)
      if (!uri.path.endsWith('/nav'))
        int.parse(
          uri.queryParameters['pn'] ?? uri.queryParameters['page_num']!,
        ),
  ];
  int get navCalls => calls.where((uri) => uri.path.endsWith('/nav')).length;
}
