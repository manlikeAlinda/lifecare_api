import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'ad_repository.dart';

/// Columns callers may set via create/update. Anything else in the request
/// body is ignored rather than erroring, so clients can send a full object
/// back on PUT without needing to strip read-only fields first.
const _writableFields = {
  'title',
  'body',
  'cta_label',
  'target_url',
  'background_color',
  'display_order',
  'start_date',
  'end_date',
  'is_active',
};

class AdService {
  final AdRepository _repo;

  AdService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> listForAdmin({
    int limit = 20,
    int offset = 0,
    String? search,
  }) =>
      _repo.findAllForAdmin(limit: limit, offset: offset, search: search);

  Future<Map<String, dynamic>> getById(String id) async {
    final ad = await _repo.findById(id);
    if (ad == null) throw ApiError.notFound('Ad not found');
    return ad;
  }

  Future<List<Map<String, dynamic>>> listActiveForPublic() =>
      _repo.findActiveForPublic();

  Future<Map<String, dynamic>> create(
    Map<String, dynamic> data,
    String actorId,
  ) async {
    final title = (data['title'] as String? ?? '').trim();
    final startDate = data['start_date'] as String?;
    final endDate = data['end_date'] as String?;

    if (title.isEmpty) throw ApiError.validationError('title is required');
    if (startDate == null || endDate == null) {
      throw ApiError.validationError('start_date and end_date are required');
    }
    _validateDateRange(startDate, endDate);
    _validateTargetUrl(data['target_url']);

    final adId = generateUuid();
    return _repo.create(
      adId: adId,
      title: title,
      body: data['body'] as String?,
      ctaLabel: data['cta_label'] as String?,
      targetUrl: data['target_url'] as String?,
      backgroundColor: data['background_color'] as String?,
      displayOrder: _parseInt(data['display_order']) ?? 0,
      startDate: startDate,
      endDate: endDate,
      isActive: _parseBool(data['is_active'] ?? true),
      createdBy: actorId,
    );
  }

  Future<Map<String, dynamic>> update(
    String id,
    Map<String, dynamic> data,
    String actorId,
  ) async {
    final existing = await _repo.findById(id);
    if (existing == null) throw ApiError.notFound('Ad not found');

    final fields = <String, dynamic>{};
    for (final key in _writableFields) {
      if (!data.containsKey(key)) continue;
      switch (key) {
        case 'title':
          final title = (data['title'] as String? ?? '').trim();
          if (title.isEmpty) throw ApiError.validationError('title cannot be empty');
          fields['title'] = title;
        case 'is_active':
          fields['is_active'] = _parseBool(data['is_active']) ? 1 : 0;
        case 'display_order':
          fields['display_order'] = _parseInt(data['display_order']) ?? 0;
        case 'target_url':
          _validateTargetUrl(data['target_url']);
          fields['target_url'] = data['target_url'];
        default:
          fields[key] = data[key];
      }
    }

    final startDate = (fields['start_date'] ?? existing['start_date']).toString();
    final endDate = (fields['end_date'] ?? existing['end_date']).toString();
    _validateDateRange(startDate, endDate);

    final updated = await _repo.update(id, fields, actorId: actorId);
    return updated!;
  }

  Future<void> archive(String id, String actorId) async {
    final deleted = await _repo.softDelete(id, actorId: actorId);
    if (!deleted) throw ApiError.notFound('Ad not found');
  }

  Future<void> hardDelete(String id, String actorId) async {
    final deleted = await _repo.hardDelete(id, actorId: actorId);
    if (!deleted) throw ApiError.notFound('Ad not found');
  }

  void _validateDateRange(String startDate, String endDate) {
    final start = DateTime.tryParse(startDate);
    final end = DateTime.tryParse(endDate);
    if (start == null || end == null) {
      throw ApiError.validationError('start_date and end_date must be valid dates');
    }
    if (end.isBefore(start)) {
      throw ApiError.validationError('end_date must not be before start_date');
    }
  }

  void _validateTargetUrl(Object? value) {
    if (value == null) return;
    final url = value.toString();
    if (url.isEmpty) return;
    final isDeepLink = url.startsWith('lifecare://');
    final isHttp = Uri.tryParse(url)?.hasScheme == true &&
        (url.startsWith('http://') || url.startsWith('https://'));
    if (!isDeepLink && !isHttp) {
      throw ApiError.validationError(
        'target_url must be an http(s) URL or a lifecare:// deep link',
      );
    }
  }

  bool _parseBool(dynamic v) {
    if (v is bool) return v;
    if (v is int) return v != 0;
    if (v is String) return v == '1' || v.toLowerCase() == 'true';
    return false;
  }

  int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
