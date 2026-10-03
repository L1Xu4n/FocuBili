import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:window_manager/window_manager.dart';

/// Exposes the active player to Linux media keys and lock-screen controls (MPRIS).
class LinuxMediaSession extends DBusObject {
  LinuxMediaSession() : super(DBusObjectPath('/org/mpris/MediaPlayer2'));
  static const rootInterface = 'org.mpris.MediaPlayer2';
  static const playerInterface = 'org.mpris.MediaPlayer2.Player';
  static LinuxMediaSession? _owner;
  DBusClient? _client;
  bool _disposed = false;
  Future<void> Function()? _play;
  Future<void> Function()? _pause;
  Future<void> Function(Duration)? _seek;
  Future<void> Function(double)? _setRate;
  String _title = '焦点哔哩';
  String _track = 'none';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _rate = 1;

  Future<void> initialize({
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function(Duration) seek,
    required Future<void> Function(double) setRate,
  }) async {
    if (!Platform.isLinux || _disposed) return;
    await _owner?.dispose();
    _owner = this;
    _play = play;
    _pause = pause;
    _seek = seek;
    _setRate = setRate;
    final client = DBusClient.session();
    _client = client;
    try {
      await client.registerObject(this);
      await client.requestName('org.mpris.MediaPlayer2.focubili.instance$pid');
    } catch (_) {
      await client.close();
      if (_client == client) _client = null;
      // Missing session D-Bus must not prevent local playback.
    }
  }

  void update({
    required String title,
    required String trackId,
    required Duration position,
    required Duration duration,
    required bool playing,
    required double speed,
  }) {
    if (_disposed) return;
    final changed =
        title != _title ||
        trackId != _track ||
        duration != _duration ||
        playing != _playing ||
        speed != _rate;
    _title = title;
    _track = trackId;
    _position = position;
    _duration = duration;
    _playing = playing;
    _rate = speed;
    if (changed && _client != null && _owner == this) {
      unawaited(
        emitPropertiesChanged(
          playerInterface,
          changedProperties: {
            'PlaybackStatus': DBusString(playing ? 'Playing' : 'Paused'),
            'Metadata': _metadata,
            'Rate': DBusDouble(speed),
          },
        ).catchError((Object _) {}),
      );
    }
  }

  DBusObjectPath get _trackPath => DBusObjectPath(
    '/org/mpris/MediaPlayer2/track/${_track.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}',
  );
  DBusValue get _metadata => DBusDict.stringVariant({
    'mpris:trackid': _trackPath,
    'mpris:length': DBusInt64(_duration.inMicroseconds),
    'xesam:title': DBusString(_title),
  });

  Map<String, DBusValue> _properties(String interface) => switch (interface) {
    rootInterface => {
      'CanQuit': const DBusBoolean(false),
      'CanRaise': const DBusBoolean(true),
      'HasTrackList': const DBusBoolean(false),
      'Identity': const DBusString('焦点哔哩'),
      'DesktopEntry': const DBusString('com.focubili.app'),
      'SupportedUriSchemes': DBusArray.string([]),
      'SupportedMimeTypes': DBusArray.string([]),
    },
    playerInterface => {
      'PlaybackStatus': DBusString(_playing ? 'Playing' : 'Paused'),
      'Metadata': _metadata,
      'Position': DBusInt64(_position.inMicroseconds),
      'Rate': DBusDouble(_rate),
      'MinimumRate': const DBusDouble(0.5),
      'MaximumRate': const DBusDouble(5),
      'CanGoNext': const DBusBoolean(false),
      'CanGoPrevious': const DBusBoolean(false),
      'CanPlay': const DBusBoolean(true),
      'CanPause': const DBusBoolean(true),
      'CanSeek': DBusBoolean(_duration > Duration.zero),
      'CanControl': const DBusBoolean(true),
    },
    _ => {},
  };

  @override
  List<DBusIntrospectInterface> introspect() => [
    for (final interface in [rootInterface, playerInterface])
      DBusIntrospectInterface(
        interface,
        methods: interface == rootInterface
            ? [DBusIntrospectMethod('Raise')]
            : [
                for (final name in ['Play', 'Pause', 'PlayPause', 'Stop'])
                  DBusIntrospectMethod(name),
                DBusIntrospectMethod(
                  'Seek',
                  args: [
                    DBusIntrospectArgument(
                      DBusSignature('x'),
                      DBusArgumentDirection.in_,
                      name: 'Offset',
                    ),
                  ],
                ),
                DBusIntrospectMethod(
                  'SetPosition',
                  args: [
                    DBusIntrospectArgument(
                      DBusSignature('o'),
                      DBusArgumentDirection.in_,
                      name: 'TrackId',
                    ),
                    DBusIntrospectArgument(
                      DBusSignature('x'),
                      DBusArgumentDirection.in_,
                      name: 'Position',
                    ),
                  ],
                ),
              ],
        properties: [
          for (final entry in _properties(interface).entries)
            DBusIntrospectProperty(
              entry.key,
              entry.value.signature,
              access: entry.key == 'Rate'
                  ? DBusPropertyAccess.readwrite
                  : DBusPropertyAccess.read,
            ),
        ],
      ),
  ];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _properties(interface)[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(_properties(interface));
  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (_disposed || _owner != this) {
      return DBusMethodErrorResponse.failed('Inactive player');
    }
    if (interface == playerInterface &&
        name == 'Rate' &&
        value is DBusDouble &&
        value.value.isFinite &&
        value.value >= 0.5 &&
        value.value <= 5) {
      try {
        await _setRate?.call(value.value);
        return DBusMethodSuccessResponse();
      } catch (_) {
        return DBusMethodErrorResponse.failed('Playback operation failed');
      }
    }
    return DBusMethodErrorResponse.propertyReadOnly();
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final call = methodCall;
    if (_disposed || _owner != this) {
      return DBusMethodErrorResponse.failed('Inactive player');
    }
    try {
      if (call.interface == rootInterface &&
          call.name == 'Raise' &&
          call.values.isEmpty) {
        await windowManager.show();
        await windowManager.focus();
      } else if (call.interface == playerInterface) {
        switch (call.name) {
          case 'Play' when call.values.isEmpty:
            await _play?.call();
          case 'Pause' || 'Stop' when call.values.isEmpty:
            await _pause?.call();
          case 'PlayPause' when call.values.isEmpty:
            if (_playing) {
              await _pause?.call();
            } else {
              await _play?.call();
            }
          case 'Seek'
              when call.values.length == 1 && call.values[0] is DBusInt64:
            await _seekBounded(
              _position.inMicroseconds + (call.values[0] as DBusInt64).value,
            );
          case 'SetPosition'
              when call.values.length == 2 &&
                  call.values[0] is DBusObjectPath &&
                  call.values[1] is DBusInt64:
            if (call.values[0] == _trackPath) {
              await _seekBounded((call.values[1] as DBusInt64).value);
            }
          default:
            return DBusMethodErrorResponse.unknownMethod();
        }
      } else {
        return DBusMethodErrorResponse.unknownMethod();
      }
      return DBusMethodSuccessResponse();
    } catch (_) {
      return DBusMethodErrorResponse.failed('Playback operation failed');
    }
  }

  Future<void> _seekBounded(int microseconds) async {
    if (_duration <= Duration.zero) return;
    await _seek?.call(
      Duration(microseconds: microseconds.clamp(0, _duration.inMicroseconds)),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    if (_owner == this) _owner = null;
    final client = _client;
    _client = null;
    await client?.close();
  }
}
