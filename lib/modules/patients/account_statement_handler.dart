import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/utils/response.dart';
import 'account_statement_service.dart';

class AccountStatementHandler {
  final AccountStatementService _service;

  AccountStatementHandler(this._service);

  Future<Response> getById(Request request, String id) async {
    final statement = await _service.generate(id);
    return okResponse(statement);
  }
}
