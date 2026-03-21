import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/middleware/auth_middleware.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'package:lifecare_api/core/validation/validator.dart';
import 'wallet_service.dart';

class WalletHandler {
  final WalletService _service;

  WalletHandler(this._service);

  Future<Response> list(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final (wallets, total) = await _service.listWallets(
      limit: limit,
      offset: offset,
    );
    return okListResponse(wallets, total: total, limit: limit, offset: offset);
  }

  Future<Response> getById(Request request, String id) async {
    final wallet = await _service.getWallet(id);
    return okResponse(wallet);
  }

  Future<Response> getGlobalLedger(Request request) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final type = queryParam(request, 'type');
    final from = queryParam(request, 'from');
    final to = queryParam(request, 'to');
    final (entries, total) = await _service.getGlobalLedger(
      limit: limit,
      offset: offset,
      type: type,
      from: from,
      to: to,
    );
    return okListResponse(entries, total: total, limit: limit, offset: offset);
  }

  Future<Response> getLedger(Request request, String id) async {
    final limit = parseLimit(request);
    final offset = parseOffset(request);
    final (entries, total) = await _service.getWalletLedger(
      id,
      limit: limit,
      offset: offset,
    );
    return okListResponse(entries, total: total, limit: limit, offset: offset);
  }

  Future<Response> getDependents(Request request, String id) async {
    final dependents = await _service.getWalletDependents(id);
    return okListResponse(dependents, total: dependents.length, limit: dependents.length, offset: 0);
  }

  Future<Response> createTransaction(Request request, String id) async {
    final body = await parseJsonBody(request);
    final caller = requireAuthUser(request);

    Validator(body)
      ..required('transaction_type')
      ..required('amount')
      ..currencyAmount('amount')
      ..throwIfInvalid();

    final entry = await _service.createTransaction(id, body, caller.id);
    return createdResponse(entry);
  }
}
