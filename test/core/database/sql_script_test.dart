import 'package:test/test.dart';
import 'package:lifecare_api/core/database/sql_script.dart';

void main() {
  group('splitSqlScript', () {
    test('splits plain statements and drops comments and blanks', () {
      expect(
        splitSqlScript('''
-- a comment
CREATE TABLE a (id INT); -- trailing comment
UPDATE a SET id = 1;

'''),
        ['CREATE TABLE a (id INT)', 'UPDATE a SET id = 1'],
      );
    });

    test('keeps semicolons inside quoted strings', () {
      expect(
        splitSqlScript("INSERT INTO t VALUES ('a;b', \"c;d\");\nSELECT 1;"),
        ["INSERT INTO t VALUES ('a;b', \"c;d\")", 'SELECT 1'],
      );
    });

    test('handles DELIMITER blocks used by the migration procedures', () {
      final stmts = splitSqlScript('''
DROP PROCEDURE IF EXISTS m;

DELIMITER //
CREATE PROCEDURE m()
BEGIN
  IF NOT EXISTS (SELECT 1) THEN
    ALTER TABLE t ADD COLUMN c INT;
  END IF;
END //
DELIMITER ;

CALL m();
DROP PROCEDURE IF EXISTS m;
''');
      expect(stmts, hasLength(4));
      expect(stmts[0], 'DROP PROCEDURE IF EXISTS m');
      expect(stmts[1], startsWith('CREATE PROCEDURE m()'));
      expect(stmts[1], contains('ALTER TABLE t ADD COLUMN c INT;'));
      expect(stmts[1], endsWith('END'));
      expect(stmts[2], 'CALL m()');
      expect(stmts[3], 'DROP PROCEDURE IF EXISTS m');
    });

    test('a "--" inside a string is not a comment', () {
      expect(splitSqlScript("SELECT '--not a comment';"), ["SELECT '--not a comment'"]);
    });
  });

  group('migrationNumber', () {
    test('reads the leading number of a migration file name', () {
      expect(migrationNumber('045_patients_primary_name_index.sql'), 45);
      expect(migrationNumber('README.md'), isNull);
    });
  });
}
