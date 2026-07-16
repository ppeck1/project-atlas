import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/shared/widgets/atlas_shell.dart';

// Destination paths from AtlasShell, in declaration order:
//   index 0 → /today
//   index 1 → /projects
//   index 2 → /work
//   index 3 → /operations
//   index 4 → /library
const _paths = ['/today', '/projects', '/work', '/operations', '/library'];

void main() {
  group('resolveNavSelectedIndex', () {
    test('returns -1 for / (root) — no highlight', () {
      expect(resolveNavSelectedIndex('/', _paths), -1);
    });

    test('returns -1 for /review — no highlight', () {
      expect(resolveNavSelectedIndex('/review', _paths), -1);
    });

    test('returns -1 for /export — no highlight', () {
      expect(resolveNavSelectedIndex('/export', _paths), -1);
    });

    test('returns -1 for /governance — no highlight', () {
      expect(resolveNavSelectedIndex('/governance', _paths), -1);
    });

    test('returns -1 for /log — no highlight', () {
      expect(resolveNavSelectedIndex('/log', _paths), -1);
    });

    test('returns 0 for /today (exact match)', () {
      expect(resolveNavSelectedIndex('/today', _paths), 0);
    });

    test('returns 1 for /projects (exact match)', () {
      expect(resolveNavSelectedIndex('/projects', _paths), 1);
    });

    test('returns 1 for /projects/abc (child path)', () {
      expect(resolveNavSelectedIndex('/projects/abc', _paths), 1);
    });

    test('returns 1 for /projects/abc/detail (deep child path)', () {
      expect(resolveNavSelectedIndex('/projects/abc/detail', _paths), 1);
    });

    test('returns 2 for /work (exact match)', () {
      expect(resolveNavSelectedIndex('/work', _paths), 2);
    });

    test('returns 3 for /operations (exact match)', () {
      expect(resolveNavSelectedIndex('/operations', _paths), 3);
    });

    test('returns 4 for /library (exact match)', () {
      expect(resolveNavSelectedIndex('/library', _paths), 4);
    });

    test('does not match /today-extra (path that merely starts with /today)', () {
      // /today-extra starts with '/today' as a string but '/today' is not
      // followed by '/' so the prefix rule should not match.
      expect(resolveNavSelectedIndex('/today-extra', _paths), -1);
    });

    test('longer prefix wins when destination paths are prefixes of each other', () {
      // Synthetic scenario: /a and /a/b are both destinations.
      // /a/b/c should resolve to index 1 (/a/b), not index 0 (/a).
      final paths = ['/a', '/a/b'];
      expect(resolveNavSelectedIndex('/a/b/c', paths), 1);
    });

    test('returns -1 for empty location against real paths', () {
      expect(resolveNavSelectedIndex('', _paths), -1);
    });
  });
}
