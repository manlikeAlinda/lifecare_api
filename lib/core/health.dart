import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:lifecare_api/core/logging/logger.dart';

const _json = {'content-type': 'application/json'};

/// GET /healthz/liveness — the process is up and serving. Never touches the
/// database, so a DB outage doesn't make the platform restart a healthy
/// process in a loop.
Response livenessResponse() =>
    Response.ok(jsonEncode({'status': 'ok'}), headers: _json);

/// GET /healthz/readiness (and /health) — can this instance actually serve
/// requests? Runs [ping] (a trivial DB query) and answers 503 if it fails or
/// takes longer than [timeout]. /health used to return "ok" unconditionally,
/// even with the database unreachable.
Future<Response> readinessResponse(
  Future<void> Function() ping, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  try {
    await ping().timeout(timeout);
    return Response.ok(jsonEncode({'status': 'ok', 'database': 'ok'}), headers: _json);
  } catch (e) {
    log.warning('Readiness check failed: database unreachable ($e)');
    return Response(
      503,
      body: jsonEncode({'status': 'unavailable', 'database': 'unreachable'}),
      headers: _json,
    );
  }
}
