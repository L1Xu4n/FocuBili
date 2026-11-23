import 'bilibili_wbi_signing_service.dart';

/// Fixed user-facing text and separate transport/business status only.
class BilibiliLookupException implements Exception, BilibiliRequestFailure {
  const BilibiliLookupException(this.message, {this.httpStatus, this.apiCode});

  final String message;
  @override
  final int? httpStatus;
  @override
  final int? apiCode;

  /// 结构化判定明确的站点风控/限流状态码（HTTP 412 或业务 -352 / -779 / -799）。
  bool get isRiskControl =>
      httpStatus == 412 ||
      apiCode == -352 ||
      apiCode == -779 ||
      apiCode == -799;

  @override
  String toString() => message;
}
