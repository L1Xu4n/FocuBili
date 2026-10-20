import 'dart:convert';
import 'dart:typed_data';

import 'package:focubili/services/desktop_player_overlay_service.dart';

/// Public signing material from the existing cross-language WBI test vector.
DesktopOverlayHttpResponse
subtitleWbiNavigation() => DesktopOverlayHttpResponse(
  statusCode: 200,
  bodyBytes: Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'code': -101,
        'data': {
          'wbi_img': {
            'img_url':
                'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
            'sub_url':
                'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
          },
        },
      }),
    ),
  ),
);
