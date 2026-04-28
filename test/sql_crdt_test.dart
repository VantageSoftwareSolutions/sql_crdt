import 'package:sql_crdt/sql_crdt.dart';
import 'package:crdt/crdt.dart';
import 'package:test/test.dart';

class MockDatabaseApi extends DatabaseApi {
  final List<List<Map<String, Object?>>> _queryResults = [];
  final List<String> _executedStatements = [];
  
  void addQueryResult(List<Map<String, Object?>> result) {
    _queryResults.add(result);
  }

  List<String> get executedStatements => List.unmodifiable(_executedStatements);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) async {
    if (_queryResults.isNotEmpty) {
      final result = _queryResults.first;
      _queryResults.removeAt(0);
      return result;
    }
    return [];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    _executedStatements.add(sql);
  }

  @override
  Future<void> transaction(Future<void> Function(ReadWriteApi api) actions) async {
    await actions(this);
  }

  @override
  Future<void> executeBatch(Future<void> Function(ReadWriteApi api) actions) async {
    await actions(this);
  }
}

class TestSqlCrdt extends SqlCrdt {
  final List<String> _tables = [];
  final Map<String, List<String>> _tableKeys = {};
  final List<Iterable<String>> _onDatasetChangedCalls = [];

  TestSqlCrdt(super.db);

  void addTable(String name, List<String> keys) {
    _tables.add(name);
    _tableKeys[name] = keys;
  }

  List<Iterable<String>> get onDatasetChangedCalls => List.unmodifiable(_onDatasetChangedCalls);

  @override
  Future<Iterable<String>> getTables() async => _tables;

  @override
  Future<Iterable<String>> getTableKeys(String table) async => _tableKeys[table] ?? [];

  @override
  Future<void> onDatasetChanged(Iterable<String> affectedTables, Hlc hlc) async {
    _onDatasetChangedCalls.add(List.from(affectedTables));
    await super.onDatasetChanged(affectedTables, hlc);
  }
}

void main() {
  group('SqlCrdt merge optimization', () {
    late MockDatabaseApi mockDb;
    late TestSqlCrdt crdt;

    setUp(() async {
      mockDb = MockDatabaseApi();
      crdt = TestSqlCrdt(mockDb);
      crdt.addTable('users', ['id']);
      crdt.addTable('devices', ['id']);
      await crdt.init('test_node');
    });

    test('onDatasetChanged called when records are actually updated', () async {
      // Simulate existing record with lower HLC
      mockDb.addQueryResult([
        {'hlc': '1970-01-01T00:00:00.000Z-0000-old_node'}
      ]);

      // Create changeset with higher HLC from different node
      final changeset = <String, List<Map<String, dynamic>>>{};
      final hlc = Hlc.zero('remote_node').increment();
      changeset['users'] = [
        {
          'id': 1,
          'name': 'John',
          'hlc': hlc,
          'modified': hlc.toString(),
          'node_id': 'remote_node',
        }
      ];

      await crdt.merge(changeset);

      expect(crdt.onDatasetChangedCalls.length, 1);
      expect(crdt.onDatasetChangedCalls.first, contains('users'));
    });

    test('onDatasetChanged NOT called when records have lower HLC', () async {
      // Simulate existing record with higher HLC
      final existingHlc = Hlc.zero('existing_node').increment();
      mockDb.addQueryResult([
        {'hlc': existingHlc.toString()}
      ]);

      // Create changeset with lower HLC from different node
      final changeset = <String, List<Map<String, dynamic>>>{};
      final oldHlc = Hlc.zero('remote_node');
      changeset['users'] = [
        {
          'id': 1,
          'name': 'John',
          'hlc': oldHlc,
          'modified': oldHlc.toString(),
          'node_id': 'remote_node',
        }
      ];

      await crdt.merge(changeset);

      expect(crdt.onDatasetChangedCalls.length, 0);
    });

    test('onDatasetChanged called only for tables that actually changed', () async {
      // Users table: existing record has lower HLC (should update)
      mockDb.addQueryResult([
        {'hlc': '1970-01-01T00:00:00.000Z-0000-old_node'}
      ]);

      // Devices table: existing record has higher HLC (should not update)
      final existingHlc = Hlc.zero('existing_node').increment();
      mockDb.addQueryResult([
        {'hlc': existingHlc.toString()}
      ]);

      final changeset = <String, List<Map<String, dynamic>>>{};
      final newHlc = Hlc.zero('remote_node1').increment();
      final oldHlc = Hlc.zero('remote_node2');

      // Add record that should update users table
      changeset['users'] = [
        {
          'id': 1,
          'name': 'John',
          'hlc': newHlc,
          'modified': newHlc.toString(),
          'node_id': 'remote_node1',
        }
      ];

      // Add record that should NOT update devices table
      changeset['devices'] = [
        {
          'id': 1,
          'name': 'Device1',
          'hlc': oldHlc,
          'modified': oldHlc.toString(),
          'node_id': 'remote_node2',
        }
      ];

      await crdt.merge(changeset);

      expect(crdt.onDatasetChangedCalls.length, 1);
      expect(crdt.onDatasetChangedCalls.first, contains('users'));
      expect(crdt.onDatasetChangedCalls.first, isNot(contains('devices')));
    });

    test('onDatasetCalled when no existing records (new inserts)', () async {
      // Simulate no existing records
      mockDb.addQueryResult([]);

      final changeset = <String, List<Map<String, dynamic>>>{};
      final hlc = Hlc.zero('remote_node').increment();
      changeset['users'] = [
        {
          'id': 1,
          'name': 'John',
          'hlc': hlc,
          'modified': hlc.toString(),
          'node_id': 'remote_node',
        }
      ];

      await crdt.merge(changeset);

      expect(crdt.onDatasetChangedCalls.length, 1);
      expect(crdt.onDatasetChangedCalls.first, contains('users'));
    });
  });
}
