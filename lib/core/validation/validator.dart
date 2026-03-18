import 'package:lifecare_api/core/errors/api_error.dart';

class Validator {
  final Map<String, dynamic> _data;
  final List<Map<String, dynamic>> _errors = [];

  Validator(this._data);

  dynamic _get(String field) => _data[field];

  Validator required(String field, {String? label}) {
    final value = _get(field);
    if (value == null || (value is String && value.trim().isEmpty)) {
      _errors.add({'field': field, 'message': '${label ?? field} is required'});
    }
    return this;
  }

  Validator email(String field, {String? label, bool optional = false}) {
    final value = _get(field);
    if (value == null) return this;
    final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!regex.hasMatch(value.toString())) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must be a valid email address',
      });
    }
    return this;
  }

  Validator phoneE164(String field, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    final regex = RegExp(r'^\+[1-9]\d{7,14}$');
    if (!regex.hasMatch(value.toString())) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must be in E.164 format (e.g. +1234567890)',
      });
    }
    return this;
  }

  Validator uuid(String field, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    final regex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    if (!regex.hasMatch(value.toString())) {
      _errors.add({'field': field, 'message': '${label ?? field} must be a valid UUID'});
    }
    return this;
  }

  Validator positiveInteger(String field, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    final intValue = value is int ? value : int.tryParse(value.toString());
    if (intValue == null || intValue <= 0) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must be a positive integer',
      });
    }
    return this;
  }

  Validator currencyAmount(String field, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    final numValue = value is num ? value.toDouble() : double.tryParse(value.toString());
    if (numValue == null || numValue < 0) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must be a non-negative amount',
      });
    }
    return this;
  }

  Validator minLength(String field, int min, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    if (value.toString().length < min) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must be at least $min characters',
      });
    }
    return this;
  }

  Validator maxLength(String field, int max, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    if (value.toString().length > max) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must not exceed $max characters',
      });
    }
    return this;
  }

  Validator oneOf(String field, List<String> values, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    if (!values.contains(value.toString())) {
      _errors.add({
        'field': field,
        'message': '${label ?? field} must be one of: ${values.join(', ')}',
      });
    }
    return this;
  }

  Validator isList(String field, {String? label}) {
    final value = _get(field);
    if (value == null) return this;
    if (value is! List) {
      _errors.add({'field': field, 'message': '${label ?? field} must be an array'});
    }
    return this;
  }

  bool get isValid => _errors.isEmpty;

  void throwIfInvalid() {
    if (_errors.isNotEmpty) {
      throw ApiError.validationError('Validation failed', details: _errors);
    }
  }
}
