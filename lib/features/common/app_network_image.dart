import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/image_resource_cache.dart';

/// Every remote cover/avatar uses the same encoded cache. Display size only
/// affects decoding, so compact and full-size widgets share one download.
class AppNetworkImage extends StatefulWidget {
  const AppNetworkImage({
    super.key,
    required this.imageUrl,
    this.httpHeaders = const {},
    this.width,
    this.height,
    this.fit,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.errorWidget,
    this.cache,
  });
  final String imageUrl;
  final Map<String, String> httpHeaders;
  final double? width, height;
  final BoxFit? fit;
  final int? memCacheWidth, memCacheHeight;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final ImageResourceCache? cache;
  @override
  State<AppNetworkImage> createState() => _AppNetworkImageState();
}

class _AppNetworkImageState extends State<AppNetworkImage> {
  ImageResourceCache get cache => widget.cache ?? ImageResourceCache.instance;
  CachedImageBytes? _data;
  Object? _error;
  int _request = 0;
  ImageProvider? _provider;
  Map<String, String> get _headers => {
    'Referer': 'https://www.bilibili.com/',
    ...widget.httpHeaders,
  };

  @override
  void initState() {
    super.initState();
    cache.addListener(_invalidated);
    _load();
  }

  @override
  void didUpdateWidget(AppNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache) {
      (oldWidget.cache ?? ImageResourceCache.instance).removeListener(
        _invalidated,
      );
      cache.addListener(_invalidated);
    }
    if (oldWidget.imageUrl != widget.imageUrl ||
        !mapEquals(oldWidget.httpHeaders, widget.httpHeaders) ||
        oldWidget.cache != widget.cache) {
      _data = null;
      _error = null;
      _load();
    }
  }

  void _invalidated() {
    _request++;
    unawaited(_provider?.evict());
    // Explicit clear leaves a placeholder. Only a later new/rebound widget may
    // download again, so visible widgets cannot silently undo the user's clear.
    if (mounted) {
      setState(() {
        _data = null;
        _error = null;
      });
    }
  }

  Future<void> _load() async {
    final token = ++_request;
    try {
      final data = await cache.load(widget.imageUrl, headers: _headers);
      if (mounted && token == _request) setState(() => _data = data);
    } catch (error) {
      if (mounted && token == _request) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    cache.removeListener(_invalidated);
    if (_data?.cacheable == false) unawaited(_provider?.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final data = _data;
        if (data == null) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: _error == null
                ? widget.placeholder?.call(context, widget.imageUrl)
                : widget.errorWidget?.call(context, widget.imageUrl, _error!) ??
                      const Icon(Icons.broken_image_outlined),
          );
        }
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final displayedWidth =
            widget.width ??
            (constraints.maxWidth.isFinite ? constraints.maxWidth : 640);
        // No disk resize variants: decode within the actual display budget.
        final pixels =
            widget.memCacheWidth ??
            (displayedWidth * ratio).ceil().clamp(1, 2048);
        _provider = ResizeImage(
          _ContentImage(data),
          width: pixels,
          height: widget.memCacheHeight,
          allowUpscaling: false,
        );
        return Image(
          image: _provider!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (context, error, stack) {
            unawaited(
              cache
                  .remove(widget.imageUrl, headers: _headers)
                  .catchError((Object _) {}),
            );
            return widget.errorWidget?.call(context, widget.imageUrl, error) ??
                const Icon(Icons.broken_image_outlined);
          },
        );
      },
    );
  }
}

/// Content identity shares Flutter's decoded cache across newly read byte
/// buffers, but includes the disk epoch/resource identity to isolate clears.
class _ContentImage extends ImageProvider<_ContentImage> {
  _ContentImage(this.data);
  final CachedImageBytes data;
  @override
  Future<_ContentImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _ContentImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _decode(decode), scale: 1);
  Future<ui.Codec> _decode(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(data.bytes));
  @override
  bool operator ==(Object other) =>
      other is _ContentImage && other.data.identity == data.identity;
  @override
  int get hashCode => data.identity.hashCode;
}
