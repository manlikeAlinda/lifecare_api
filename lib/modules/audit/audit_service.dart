import 'audit_repository.dart';

class AuditService {
  final AuditRepository _repo;

  AuditService(this._repo);

  Future<(List<Map<String, dynamic>>, int)> list({
    int limit = 20,
    int offset = 0,
    String? beneficiaryId,
    String? actorId,
    String? action,
  }) =>
      _repo.list(
        limit: limit,
        offset: offset,
        beneficiaryId: beneficiaryId,
        actorId: actorId,
        action: action,
      );
}
