import 'dart:convert';

import 'package:test/test.dart';
import 'package:lifecare_api/core/health.dart';

void main() {
  test('readiness is 200 when the database answers', () async {
    final res = await readinessResponse(() async {});
    expect(res.statusCode, 200);
    expect(jsonDecode(await res.readAsString()), {'status': 'ok', 'database': 'ok'});
  });

  test('readiness is 503 when the database query fails', () async {
    final res = await readinessResponse(() async => throw Exception('Access denied'));
    expect(res.statusCode, 503);
    expect(jsonDecode(await res.readAsString())['database'], 'unreachable');
  });

  test('readiness is 503 when the database hangs past the timeout', () async {
    final res = await readinessResponse(
      () => Future<void>.delayed(const Duration(seconds: 5)),
      timeout: const Duration(milliseconds: 50),
    );
    expect(res.statusCode, 503);
  });

  test('liveness does not touch the database', () async {
    final res = livenessResponse();
    expect(res.statusCode, 200);
  });
}
