/// Splits a migration file into individual statements for the migration
/// runner (bin/migrate.dart). Understands what our migrations use:
/// `-- comments`, quoted strings, and `DELIMITER //` blocks around stored
/// procedures (a mysql-CLI feature the database driver doesn't parse).
List<String> splitSqlScript(String script) {
  final statements = <String>[];
  var delimiter = ';';
  final current = StringBuffer();

  void flush() {
    final s = current.toString().trim();
    if (s.isNotEmpty) statements.add(s);
    current.clear();
  }

  for (final rawLine in script.split('\n')) {
    final line = rawLine.replaceAll('\r', '');
    final trimmed = line.trim();
    final delimiterDirective =
        RegExp(r'^DELIMITER\s+(\S+)\s*$', caseSensitive: false).firstMatch(trimmed);
    if (delimiterDirective != null) {
      flush();
      delimiter = delimiterDirective.group(1)!;
      continue;
    }

    // Walk the line tracking quotes, so ';' or '--' inside a string is data.
    String? quote;
    var i = 0;
    while (i < line.length) {
      final ch = line[i];
      if (quote != null) {
        current.write(ch);
        if (ch == '\\' && i + 1 < line.length) {
          current.write(line[i + 1]);
          i += 2;
          continue;
        }
        if (ch == quote) quote = null;
        i++;
        continue;
      }
      if (ch == "'" || ch == '"' || ch == '`') {
        quote = ch;
        current.write(ch);
        i++;
        continue;
      }
      if (line.startsWith('--', i)) break; // rest of line is a comment
      if (line.startsWith(delimiter, i)) {
        flush();
        i += delimiter.length;
        continue;
      }
      current.write(ch);
      i++;
    }
    current.write('\n');
  }
  flush();
  return statements;
}

/// The leading number of a migration file name ('045_x.sql' → 45), or null
/// for anything that isn't a numbered migration.
int? migrationNumber(String fileName) =>
    int.tryParse(RegExp(r'^(\d+)_').firstMatch(fileName)?.group(1) ?? '');
