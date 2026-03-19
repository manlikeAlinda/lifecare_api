import 'dart:convert';
import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/errors/api_error.dart';
import 'package:lifecare_api/core/utils/uuid.dart';
import 'auth_repository.dart';

class AuthService {
  final AuthRepository _repo;

  AuthService(this._repo);

  Future<Map<String, dynamic>> login({
    String? username,
    String? email,
    required String password,
  }) async {
    Map<String, dynamic>? user;
    if (username != null && username.isNotEmpty) {
      user = await _repo.findUserByUsername(username);
    } else if (email != null && email.isNotEmpty) {
      user = await _repo.findUserByEmail(email);
    }
    if (user == null) throw ApiError.unauthenticated('Invalid credentials');

    if (user['is_active'] == false) {
      throw ApiError.forbidden('Account is inactive');
    }

    final storedHash = user['password_hash'] as String;
    final rawAlg = user['hash_algorithm'] as String? ?? '';
    final algorithm = rawAlg.isEmpty ? 'sha256' : rawAlg;
    final userId = user['id'] as String;
    bool verified = false;

    if (algorithm == 'sha256') {
      // SHA-256: live DB stores raw 32 binary bytes; compare byte-for-byte
      final inputBytes = sha256.convert(utf8.encode(password)).bytes;
      final storedBytes = storedHash.codeUnits;
      verified = inputBytes.length == storedBytes.length &&
          List.generate(inputBytes.length, (i) => inputBytes[i] == storedBytes[i])
              .every((b) => b);
      if (verified) {
        // Migrate to bcrypt on successful login
        final bcryptHash = BCrypt.hashpw(password, BCrypt.gensalt());
        await _repo.updatePasswordHash(userId, bcryptHash, 'bcrypt');
      }
    } else {
      verified = BCrypt.checkpw(password, storedHash);
    }

    if (!verified) throw ApiError.unauthenticated('Invalid credentials');

    return _issueTokens(
      userId: userId,
      role: user['role'] as String,
      username: user['username'] as String,
    );
  }

  Future<Map<String, dynamic>> refresh(String refreshToken) async {
    final tokenHash = _hashToken(refreshToken);
    final session = await _repo.findActiveSession(tokenHash);

    if (session == null) {
      throw ApiError.unauthenticated('Invalid or expired refresh token');
    }

    if (session['is_active'] == false) {
      throw ApiError.forbidden('Account is inactive');
    }

    // Rotate: revoke old session, issue new tokens
    await _repo.revokeSessionByToken(tokenHash);

    return _issueTokens(
      userId: session['user_id'] as String,
      role: session['role'] as String,
      username: session['username'] as String,
    );
  }

  Future<void> logout(String refreshToken) async {
    final tokenHash = _hashToken(refreshToken);
    await _repo.revokeSessionByToken(tokenHash);
  }

  Future<Map<String, dynamic>> _issueTokens({
    required String userId,
    required String role,
    required String username,
  }) async {
    final accessToken = _generateAccessToken(
      userId: userId,
      role: role,
      username: username,
    );

    final refreshToken = generateUuid() + generateUuid(); // 72-char opaque token
    final refreshTokenHash = _hashToken(refreshToken);
    final sessionId = generateUuid();
    final expiresAt = DateTime.now().add(
      Duration(days: AppConfig.jwtRefreshExpiryDays),
    );

    await _repo.createSession(
      sessionId: sessionId,
      userId: userId,
      refreshTokenHash: refreshTokenHash,
      role: role,
      expiresAt: expiresAt,
    );

    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'token_type': 'Bearer',
      'expires_in': AppConfig.jwtAccessExpiryMinutes * 60,
    };
  }

  String _generateAccessToken({
    required String userId,
    required String role,
    required String username,
  }) {
    final jwt = JWT({
      'sub': userId,
      'role': role,
      'username': username,
      'type': 'access',
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    return jwt.sign(
      SecretKey(AppConfig.jwtSecret),
      expiresIn: Duration(minutes: AppConfig.jwtAccessExpiryMinutes),
    );
  }

  Future<String> issuePatientAccessToken({
    required String patientId,
    required String phone,
    required String patientCode,
  }) async {
    final jwt = JWT({
      'sub': patientId,
      'sub_type': 'patient',
      'phone': phone,
      'patient_code': patientCode,
      'type': 'access',
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    return jwt.sign(
      SecretKey(AppConfig.jwtSecret),
      expiresIn: Duration(minutes: AppConfig.jwtAccessExpiryMinutes),
    );
  }

  String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
