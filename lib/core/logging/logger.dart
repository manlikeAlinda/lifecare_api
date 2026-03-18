import 'package:logging/logging.dart';

final log = Logger('lifecare');

void setupLogging({bool verbose = false}) {
  Logger.root.level = verbose ? Level.ALL : Level.INFO;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String();
    final level = record.level.name.padRight(7);
    final message = '[$time] $level ${record.loggerName}: ${record.message}';
    // ignore: avoid_print
    print(message);
    if (record.error != null) {
      // ignore: avoid_print
      print('  ERROR: ${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('  STACK: ${record.stackTrace}');
    }
  });
}
