import 'package:shared_preferences/shared_preferences.dart';

/// One optional device-local override. Async preferences avoid an optimistic
/// in-memory value becoming active when the platform rejects a write.
class HttpUserAgentPreferences {
  const HttpUserAgentPreferences({this.readValue, this.writeValue});

  static const storageKey = 'network.http_user_agent_override.v1';
  final Future<String?> Function()? readValue;
  final Future<void> Function(String? value)? writeValue;

  Future<String?> load() async {
    final reader = readValue;
    final value = reader == null
        ? await SharedPreferencesAsync().getString(storageKey)
        : await reader();
    return HttpUserAgentInput.normalize(value ?? '');
  }

  /// Invalid or unavailable storage preserves each adapter's original header.
  Future<String?> forRequest() async {
    try {
      return await load();
    } catch (_) {
      return null;
    }
  }

  Future<String?> save(String raw) async {
    final value = HttpUserAgentInput.normalize(raw);
    final writer = writeValue;
    if (writer != null) {
      await writer(value);
    } else {
      final preferences = SharedPreferencesAsync();
      if (value == null) {
        await preferences.remove(storageKey);
      } else {
        await preferences.setString(storageKey, value);
      }
    }
    return value;
  }
}

/// Validates an RFC 9110 product list with optional HTTP comments. For
/// predictable interoperability no control bytes (including tabs) or non-ASCII
/// bytes are accepted. Errors never contain the supplied header.
abstract final class HttpUserAgentInput {
  static const maxLength = 512;
  static const _tokenSymbols =
      "!#\$%&'*+-.^_"
      '`|~';

  static String? normalize(String raw) {
    if (raw.length > maxLength) {
      throw const FormatException('User-Agent 最多 512 个 ASCII 字符。');
    }
    if (raw.codeUnits.any((code) => code < 0x20 || code > 0x7e)) {
      throw const FormatException('只接受单行 ASCII，不允许换行、制表符或控制字符。');
    }
    final value = raw.trim();
    if (value.isEmpty) return null;
    var cursor = 0;
    bool take(int ascii) {
      if (cursor == value.length || value.codeUnitAt(cursor) != ascii) {
        return false;
      }
      cursor++;
      return true;
    }

    bool token() {
      final start = cursor;
      while (cursor < value.length) {
        final code = value.codeUnitAt(cursor);
        if (!(code >= 48 && code <= 57 ||
            code >= 65 && code <= 90 ||
            code >= 97 && code <= 122 ||
            _tokenSymbols.contains(String.fromCharCode(code)))) {
          break;
        }
        cursor++;
      }
      return cursor != start;
    }

    bool product() => token() && (!take(47) || token());

    bool comment() {
      var depth = 1; // Opening '(' was already consumed.
      while (cursor < value.length) {
        final code = value.codeUnitAt(cursor++);
        if (code == 92) {
          if (cursor == value.length) return false;
          cursor++; // A quoted-pair can include a literal parenthesis.
        } else if (code == 40) {
          depth++;
        } else if (code == 41 && --depth == 0) {
          return true;
        }
      }
      return false;
    }

    const invalid = FormatException('请输入标准 User-Agent，例如使用「客户端名/版本」格式。');
    if (!product()) throw invalid;
    while (cursor < value.length) {
      if (!take(32)) throw invalid;
      while (take(32)) {}
      if (!(take(40) ? comment() : product())) throw invalid;
    }
    return value;
  }
}
