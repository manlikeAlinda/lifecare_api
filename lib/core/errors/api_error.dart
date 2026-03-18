class ApiError implements Exception {
  final int statusCode;
  final String code;
  final String message;
  final List<Map<String, dynamic>> details;

  const ApiError({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details = const [],
  });

  factory ApiError.validationError(
    String message, {
    List<Map<String, dynamic>> details = const [],
  }) =>
      ApiError(
        statusCode: 400,
        code: 'VALIDATION_ERROR',
        message: message,
        details: details,
      );

  factory ApiError.unauthenticated([String message = 'Authentication required']) =>
      ApiError(statusCode: 401, code: 'UNAUTHENTICATED', message: message);

  factory ApiError.tokenExpired() => ApiError(
        statusCode: 401,
        code: 'TOKEN_EXPIRED',
        message: 'Access token has expired',
      );

  factory ApiError.forbidden([String message = 'Insufficient permissions']) =>
      ApiError(statusCode: 403, code: 'FORBIDDEN', message: message);

  factory ApiError.notFound([String message = 'Resource not found']) =>
      ApiError(statusCode: 404, code: 'NOT_FOUND', message: message);

  factory ApiError.conflict([String message = 'Resource already exists']) =>
      ApiError(statusCode: 409, code: 'CONFLICT', message: message);

  factory ApiError.businessRule(String message) =>
      ApiError(statusCode: 422, code: 'BUSINESS_RULE', message: message);

  factory ApiError.rateLimited() =>
      ApiError(statusCode: 429, code: 'RATE_LIMITED', message: 'Too many requests');

  factory ApiError.internal([String message = 'An internal error occurred']) =>
      ApiError(statusCode: 500, code: 'INTERNAL_ERROR', message: message);

  Map<String, dynamic> toJson(String requestId) => {
        'error': {
          'code': code,
          'message': message,
          if (details.isNotEmpty) 'details': details,
          'request_id': requestId,
        },
      };

  @override
  String toString() => 'ApiError($statusCode, $code): $message';
}
