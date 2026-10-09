import 'package:dio/dio.dart';

class ApiException implements Exception
{
  static const String networkCode = 'NETWORK';
  static const String unknownCode = 'UNKNOWN';

  final int? statusCode;
  final String code;
  final String? field;

  const ApiException({this.statusCode, required this.code, this.field});

  factory ApiException.from(Object aError)
  {
    if (aError is ApiException)
    {
      return aError;
    }

    if (aError is DioException)
    {
      final response = aError.response;
      final data = response?.data;

      if (data is Map && data['code'] is String)
      {
        return ApiException(
          statusCode: response?.statusCode,
          code: data['code'] as String,
          field: data['field'] as String?,
        );
      }

      if (response == null)
      {
        return const ApiException(code: networkCode);
      }

      return ApiException(statusCode: response.statusCode, code: unknownCode);
    }

    return const ApiException(code: unknownCode);
  }

  bool get isUnauthenticated => statusCode == 401;

  String get messageKey => 'errors.$code';

  @override
  String toString() => 'ApiException($statusCode, $code, $field)';
}
