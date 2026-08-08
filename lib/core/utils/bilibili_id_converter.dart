/// 在 B 站旧 AV 号与当前 BV 号之间执行公开编号算法转换。
///
/// 兼容常量与排列参考 GPL-3.0 开源项目 PiliPlus 的 `IdUtils.av2bv` 实现。
abstract final class BilibiliIdConverter {
  static const int _xorCode = 23442827791579;
  static const int _maximumAidMask = 1 << 51;
  static const int _base = 58;
  static const String _alphabet =
      'FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf';

  /// 将大于零的 AV 数字编号转换成 B 站接口可直接查询的 BV 号。
  static String? avToBv(int aid) {
    if (aid <= 0 || aid >= _maximumAidMask) {
      return null;
    }
    final List<String> characters = 'BV1000000000'.split('');
    int index = characters.length - 1;
    int value = (_maximumAidMask | aid) ^ _xorCode;
    while (value > 0 && index >= 0) {
      characters[index] = _alphabet[value % _base];
      value ~/= _base;
      index -= 1;
    }
    _swap(characters, 3, 9);
    _swap(characters, 4, 7);
    return characters.join();
  }

  /// 交换编号字符中的两个固定位置，完成 AV/BV 算法要求的重排。
  static void _swap(List<String> values, int first, int second) {
    final String temporary = values[first];
    values[first] = values[second];
    values[second] = temporary;
  }
}
