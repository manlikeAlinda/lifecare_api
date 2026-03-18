import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server/gmail.dart';
import 'package:lifecare_api/core/config/app_config.dart';
import 'package:lifecare_api/core/logging/logger.dart';

class EmailService {
  bool get _isConfigured =>
      AppConfig.smtpUser.isNotEmpty && AppConfig.smtpPassword.isNotEmpty;

  Future<bool> sendActivationEmail({
    required String toEmail,
    required String patientCode,
    required String pin,
  }) async {
    if (!_isConfigured) return false;
    try {
      final smtpServer = gmail(AppConfig.smtpUser, AppConfig.smtpPassword);
      final message = Message()
        ..from = Address(AppConfig.smtpUser, 'LifeCare')
        ..recipients.add(toEmail)
        ..subject = 'Your LifeCare Mobile App Credentials'
        ..text = '''Welcome to LifeCare Mobile!

Your login credentials:
  Username: $patientCode
  First-time PIN: $pin

Please open the LifeCare app, go to Activate Account, enter your phone number and this PIN, then set a new password.

If you did not request this, please contact the clinic immediately.
''';
      await send(message, smtpServer);
      return true;
    } on MailerException catch (e) {
      log.warning('Activation email failed: $e');
      return false;
    }
  }

  Future<bool> sendResetEmail({
    required String toEmail,
    required String patientCode,
    required String pin,
  }) async {
    if (!_isConfigured) return false;
    try {
      final smtpServer = gmail(AppConfig.smtpUser, AppConfig.smtpPassword);
      final message = Message()
        ..from = Address(AppConfig.smtpUser, 'LifeCare')
        ..recipients.add(toEmail)
        ..subject = 'LifeCare — Your credentials have been reset'
        ..text = '''Your LifeCare Mobile credentials have been reset.

Your new login details:
  Username: $patientCode
  New PIN: $pin

Please open the LifeCare app, go to Activate Account, enter your phone number and this PIN, then set a new password.

If you did not request this, please contact the clinic immediately.
''';
      await send(message, smtpServer);
      return true;
    } on MailerException catch (e) {
      log.warning('Reset email failed: $e');
      return false;
    }
  }
}
