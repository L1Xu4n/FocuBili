import 'bilibili_wbi_signing_service.dart';

/// Fixed user-facing text and separate transport/business status only.
class BilibiliLookupException implements Exception, BilibiliRequestFailure {
  const BilibiliLookupException(this.message, {this.httpStatus, this.apiCode});

  final String message;
  @override
  final int? httpStatus;
  @override
  final int? apiCode;

  @override
  String toString() => message;
}
