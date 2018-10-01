// File created by
// Lung Razvan <long1eu>
// on 01/10/2018

import 'dart:async';

import 'package:firebase_database_collection/firebase_database_collection.dart';
import 'package:firebase_firestore/src/firebase/firestore/auth/user.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/mutation_queue.dart';
import 'package:firebase_firestore/src/firebase/firestore/local/sqlite_persistence.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/document_key.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/mutation/mutation_batch.dart';
import 'package:firebase_firestore/src/firebase/firestore/remote/write_stream.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/database_impl.dart';
import 'package:firebase_firestore/src/firebase/timestamp.dart';
import 'package:test/test.dart';

import 'cases/mutation_queue_test_case.dart';
import 'persistence_test_helpers.dart';

void main() {
  MutationQueueTestCase testCase;
  MutationQueue mutationQueue;

  setUp(() async {
    print('setUp');
    final SQLitePersistence persistence = await PersistenceTestHelpers.openSQLitePersistence(
        'firebase/firestore/local/sqlite_mutation_queue_${PersistenceTestHelpers.nextSQLiteDatabaseName()}.db');

    testCase = MutationQueueTestCase(persistence);
    await testCase.setUp(persistence.opener.db);

    mutationQueue = testCase.mutationQueue;
    print('setUpDone');
  });

  tearDown(() => Future<void>.delayed(const Duration(milliseconds: 250), () => testCase.tearDown()));

  test('testCountBatches', () async {
    await testCase.expectCount(count: 0, isEmpty: true);

    final MutationBatch batch1 = await testCase.addMutationBatch();
    await testCase.expectCount(count: 1, isEmpty: false);

    final MutationBatch batch2 = await testCase.addMutationBatch();
    await testCase.expectCount(count: 2, isEmpty: false);

    await testCase.removeMutationBatches(<MutationBatch>[batch2]);
    await testCase.expectCount(count: 1, isEmpty: false);

    await testCase.removeMutationBatches(<MutationBatch>[batch1]);
    await testCase.expectCount(count: 0, isEmpty: true);
  });

  test('testAcknowledgeBatchId', () async {
    // Initial state of an empty queue
    expect(mutationQueue.highestAcknowledgedBatchId, MutationBatch.unknown);

    // Adding mutation batches should not change the highest acked batchId.
    final MutationBatch batch1 = await testCase.addMutationBatch();
    final MutationBatch batch2 = await testCase.addMutationBatch();
    final MutationBatch batch3 = await testCase.addMutationBatch();
    expect(batch1.batchId, greaterThan(MutationBatch.unknown));
    expect(batch2.batchId, greaterThan(batch1.batchId));
    expect(batch3.batchId, greaterThan(batch2.batchId));

    expect(mutationQueue.highestAcknowledgedBatchId, MutationBatch.unknown);

    await testCase.acknowledgeBatch(batch1);
    expect(mutationQueue.highestAcknowledgedBatchId, batch1.batchId);

    await testCase.acknowledgeBatch(batch2);
    expect(mutationQueue.highestAcknowledgedBatchId, batch2.batchId);

    await testCase.removeMutationBatches(<MutationBatch>[batch1]);
    expect(mutationQueue.highestAcknowledgedBatchId, batch2.batchId);

    await testCase.removeMutationBatches(<MutationBatch>[batch2]);
    expect(mutationQueue.highestAcknowledgedBatchId, batch2.batchId);

    // Batch 3 never acknowledged.
    await testCase.removeMutationBatches(<MutationBatch>[batch3]);
    expect(mutationQueue.highestAcknowledgedBatchId, batch2.batchId);
  });

  test('testAcknowledgeThenRemove', () async {
    final MutationBatch batch1 = await testCase.addMutationBatch();

    await testCase.persistence.runTransaction('testAcknowledgeThenRemove', (DatabaseExecutor tx) async {
      await mutationQueue.acknowledgeBatch(tx, batch1, WriteStream.emptyStreamToken);
      await mutationQueue.removeMutationBatches(tx, <MutationBatch>[batch1]);
    });

    await testCase.expectCount(count: 0, isEmpty: true);
    expect(mutationQueue.highestAcknowledgedBatchId, batch1.batchId);
  });

  test('testHighestAcknowledgedBatchIdNeverExceedsNextBatchId', () async {
    final MutationBatch batch1 = await testCase.addMutationBatch();
    final MutationBatch batch2 = await testCase.addMutationBatch();
    await testCase.acknowledgeBatch(batch1);
    await testCase.acknowledgeBatch(batch2);
    expect(mutationQueue.highestAcknowledgedBatchId, batch2.batchId);

    await testCase.removeMutationBatches(<MutationBatch>[batch1, batch2]);
    expect(mutationQueue.highestAcknowledgedBatchId, batch2.batchId);

    // Restart the queue so that nextBatchId will be reset.
    mutationQueue = testCase.persistence.getMutationQueue(User.unauthenticated);
    await mutationQueue.start((testCase.persistence as SQLitePersistence).opener.db);

    await testCase.persistence.runTransaction('Start mutationQueue', (DatabaseExecutor tx) => mutationQueue.start(tx));

    // Verify that on restart with an empty queue, nextBatchId falls to a lower value.
    expect(lessThan(batch2.batchId), mutationQueue.nextBatchId);

    // As a result highestAcknowledgedBatchId must also reset lower.
    expect(mutationQueue.highestAcknowledgedBatchId, MutationBatch.unknown);

    // The mutation queue will reset the next batchId after all mutations are removed so adding
    // another mutation will cause a collision.
    final MutationBatch newBatch = await testCase.addMutationBatch();
    expect(newBatch.batchId, batch1.batchId);

    // Restart the queue with one unacknowledged batch in it.
    await testCase.persistence.runTransaction('Start mutationQueue', (DatabaseExecutor tx) => mutationQueue.start(tx));

    expect(mutationQueue.nextBatchId, newBatch.batchId + 1);

    // highestAcknowledgedBatchId must still be MutationBatch.unknown.
    expect(mutationQueue.highestAcknowledgedBatchId, MutationBatch.unknown);
  });

  test('testLookupMutationBatch', () async {
    await testCase.persistence.runTransaction('testLookupMutationBatch', (DatabaseExecutor tx) async {
      // Searching on an empty queue should not find a non-existent batch
      MutationBatch notFound = await mutationQueue.lookupMutationBatch(tx, 42);
      expect(notFound, isNull);

      final List<MutationBatch> batches = await testCase.createBatches(10);
      final List<MutationBatch> removed = await testCase.makeHoles(<int>[2, 6, 7], batches);

      // After removing, a batch should not be found
      for (MutationBatch batch in removed) {
        notFound = await mutationQueue.lookupMutationBatch(tx, batch.batchId);
        expect(notFound, isNull);
      }

      // Remaining entries should still be found
      for (MutationBatch batch in batches) {
        final MutationBatch found = await mutationQueue.lookupMutationBatch(tx, batch.batchId);
        expect(found, isNotNull);
        expect(found.batchId, batch.batchId);
      }

      // Even on a nonempty queue searching should not find a non-existent batch
      notFound = await mutationQueue.lookupMutationBatch(tx, 42);
      expect(notFound, isNull);
    });
  });

  test('testNextMutationBatchAfterBatchId', () async {
    await testCase.persistence.runTransaction('testNextMutationBatchAfterBatchId', (DatabaseExecutor tx) async {
      final List<MutationBatch> batches = await testCase.createBatches(10);

      // This is an array of successors assuming the removals below will happen:
      final List<MutationBatch> afters = <MutationBatch>[batches[3], batches[8], batches[8]];
      final List<MutationBatch> removed = await testCase.makeHoles(<int>[2, 6, 7], batches);

      for (int i = 0; i < batches.length - 1; i++) {
        final MutationBatch current = batches[i];
        final MutationBatch next = batches[i + 1];
        final MutationBatch found = await mutationQueue.getNextMutationBatchAfterBatchId(tx, current.batchId);
        expect(found, isNotNull);
        expect(found.batchId, next.batchId);
      }

      for (int i = 0; i < removed.length; i++) {
        final MutationBatch current = removed[i];
        final MutationBatch next = afters[i];
        final MutationBatch found = await mutationQueue.getNextMutationBatchAfterBatchId(tx, current.batchId);
        expect(found, isNotNull);
        expect(found.batchId, next.batchId);
      }

      final MutationBatch first = batches[0];
      final MutationBatch found = await mutationQueue.getNextMutationBatchAfterBatchId(tx, first.batchId - 42);
      expect(found, isNotNull);
      expect(found.batchId, first.batchId);

      final MutationBatch last = batches[batches.length - 1];
      final MutationBatch notFound = await mutationQueue.getNextMutationBatchAfterBatchId(tx, last.batchId);
      expect(notFound, isNull);
    });
  });

  test('testNextMutationBatchAfterBatchIdSkipsAcknowledgedBatches', () async {
    await testCase.persistence.runTransaction('testNextMutationBatchAfterBatchIdSkipsAcknowledgedBatches', (DatabaseExecutor tx) async {
      final List<MutationBatch> batches = await testCase.createBatches(3);
      expect(expectAsync0(() => mutationQueue.getNextMutationBatchAfterBatchId(tx, MutationBatch.unknown)), batches[0]);

      await testCase.acknowledgeBatch(batches[0]);
      expect(expectAsync0(() => mutationQueue.getNextMutationBatchAfterBatchId(tx, MutationBatch.unknown)), batches[1]);
      expect(expectAsync0(() => mutationQueue.getNextMutationBatchAfterBatchId(tx, batches[0].batchId)), batches[1]);
      expect(expectAsync0(() => mutationQueue.getNextMutationBatchAfterBatchId(tx, batches[1].batchId)), batches[2]);
    });
  });

  test('testAllMutationBatchesThroughBatchID', () async {
    await testCase.persistence.runTransaction('testAllMutationBatchesThroughBatchID', (DatabaseExecutor tx) async {
      final List<MutationBatch> batches = await testCase.createBatches(10);
      await testCase.makeHoles(<int>[2, 6, 7], batches);

      List<MutationBatch> found;
      List<MutationBatch> expected;

      found = await mutationQueue.getAllMutationBatchesThroughBatchId(tx, batches[0].batchId - 1);
      expect(found, isEmpty);

      for (int i = 0; i < batches.length; i++) {
        found = await mutationQueue.getAllMutationBatchesThroughBatchId(tx, batches[i].batchId);
        expected = batches.sublist(0, i + 1);
        expect(found, expected);
      }
    });
  });

  test('testAllMutationBatchesAffectingDocumentKey', () async {
    await testCase.persistence.runTransaction('testAllMutationBatchesAffectingDocumentKey', (DatabaseExecutor tx) async {
      final List<Mutation> mutations = <Mutation>[
        setMutation('fob/bar', map(<dynamic>['a', 1])),
        setMutation('foo/bar', map(<dynamic>['a', 1])),
        patchMutation('foo/bar', map(<dynamic>['b', 1])),
        setMutation('foo/bar/suffix/key', map(<dynamic>['a', 1])),
        setMutation('foo/baz', map(<dynamic>['a', 1])),
        setMutation('food/bar', map(<dynamic>['a', 1]))
      ];

      // Store all the mutations.
      final List<MutationBatch> batches = <MutationBatch>[];
      await testCase.persistence.runTransaction('New mutation batch', (DatabaseExecutor tx) async {
        for (Mutation mutation in mutations) {
          batches.add(await mutationQueue.addMutationBatch(tx, Timestamp.now(), <Mutation>[mutation]));
        }
      });

      final List<MutationBatch> expected = <MutationBatch>[batches[1], batches[2]];
      final List<MutationBatch> matches = await mutationQueue.getAllMutationBatchesAffectingDocumentKey(tx, key('foo/bar'));

      expect(matches, expected);
    });
  });

  /*
  test('testAllMutationBatchesAffectingDocumentKeys', () async {
    final List<Mutation> mutations = <Mutation>[
      setMutation('fob/bar', map('a', 1)),
      setMutation('foo/bar', map('a', 1)),
      patchMutation('foo/bar', map('b', 1)),
      setMutation('foo/bar/suffix/key', map('a', 1)),
      setMutation('foo/baz', map('a', 1)),
      setMutation('food/bar', map('a', 1))
    ];

    // Store all the mutations.
    final List<MutationBatch> batches = <MutationBatch>[];
    await testCase.persistence.runTransaction('New mutation batch', (tx) {
      for (Mutation mutation in mutations) {
        batches.add(mutationQueue.addMutationBatch(tx, Timestamp.now(), [mutation]));
      }
    });

    final ImmutableSortedSet<DocumentKey> keys = DocumentKey.emptyKeySet.insert(key('foo/bar')).insert(key('foo/baz'));

    List<MutationBatch> expected = asList(batches[1], batches[2], batches[4]);
    List<MutationBatch> matches = mutationQueue.getAllMutationBatchesAffectingDocumentKeys(keys);

    expect(matches, expected);
  });

  // PORTING NOTE: this test only applies to Android, because it's the only platform where the
  // implementation of getAllMutationBatchesAffectingDocumentKeys might split the input into several
  // queries.
  test('testAllMutationBatchesAffectingDocumentLotsOfDocumentKeys', () async {
    List<Mutation> mutations = [];
    // Make sure to force SQLite implementation to split the large query into several smaller ones.
    int lotsOfMutations = 2000;
    for (int i = 0; i < lotsOfMutations; i++) {
      mutations.add(setMutation('foo/' + i, map('a', 1)));
    }
    List<MutationBatch> batches = [];
    await testCase.persistence.runTransaction(
        'New mutation batch',
            () {
          for (Mutation mutation : mutations) {
            batches.add(mutationQueue.addMutationBatch(
                Timestamp.now(), [mutation]));
          }
        });

    // To make it easier validating the large resulting set, use a simple criteria to evaluate --
    // query all keys with an even number in them and make sure the corresponding batches make it
    // into the results.
    ImmutableSortedSet<DocumentKey> evenKeys = DocumentKey.emptyKeySet();
    List<MutationBatch> expected = [];
    for (int i = 2; i < lotsOfMutations; i += 2) {
      evenKeys = evenKeys.insert(key('foo/' + i));
      expected.add(batches[i]);
    }

    List<MutationBatch> matches =
    mutationQueue.getAllMutationBatchesAffectingDocumentKeys(evenKeys);
    assertThat(matches).containsExactlyElementsIn(expected).inOrder();
  });


  test('testAllMutationBatchesAffectingQuery', () async {
    List<Mutation> mutations =
    asList(
        setMutation('fob/bar', map('a', 1)),
        setMutation('foo/bar', map('a', 1)),
        patchMutation('foo/bar', map('b', 1)),
        setMutation('foo/bar/suffix/key', map('a', 1)),
        setMutation('foo/baz', map('a', 1)),
        setMutation('food/bar', map('a', 1)));

    // Store all the mutations.
    List<MutationBatch> batches = [];
    await testCase.persistence.runTransaction(
        'New mutation batch',
            () {
          for (Mutation mutation in mutations) {
            batches.add(mutationQueue.addMutationBatch(
                Timestamp.now(), [mutation]));
          }
        });

    List<MutationBatch> expected = asList(
        batches[1], batches[2], batches[4]);

    Query query = Query.atPath(path('foo'));
    List<MutationBatch> matches = mutationQueue
        .getAllMutationBatchesAffectingQuery(query);

    expect(matches, expected);
  });


  test('testAllMutationBatchesAffectingQuery_withCompoundBatches', () async {
    Map<String, Object> value = map('a', 1);

    // Store all the mutations.
    List<MutationBatch> batches = [];
    await testCase.persistence.runTransaction(
        'New mutation batch',
            () {
          batches.add(
              mutationQueue.addMutationBatch(
                  Timestamp.now(),
                  asList(setMutation('foo/bar', value), setMutation('foo/bar/baz/quux', value))));
          batches.add(
              mutationQueue.addMutationBatch(
                  Timestamp.now(),
                  asList(setMutation('foo/bar', value), setMutation('foo/baz', value))));
        });

    List<MutationBatch> expected = [batches[0], batches[1]];

    Query query = Query.atPath(path('foo'));
    List<MutationBatch> matches = mutationQueue
        .getAllMutationBatchesAffectingQuery(query);

    expect(matches, expected);
  });

  test('testRemoveMutationBatches', () async {
    List<MutationBatch> batches = await testCase.createBatches(10);
    MutationBatch last = batches[batches.length - 1];

    await testCase.removeMutationBatches(<MutationBatch>[batches.remove(0)]);
    expect(batchCount(), 9);

    List<MutationBatch> found;

    found =
        mutationQueue.getAllMutationBatchesThroughBatchId(last.batchId);
    expect(found, batches);
    expect(found.length, 9);

    await testCase.removeMutationBatches(
        <MutationBatch>[batches[0], batches[1], batches[2]]);
    batches.remove(batches[0]);
    batches.remove(batches[0]);
    batches.remove(batches[0]);
    expect(batchCount(), 6);

    found =
        mutationQueue.getAllMutationBatchesThroughBatchId(last.batchId);
    expect(found, batches);
    expect(found.length, 6);

    await testCase.removeMutationBatches(
        <MutationBatch>[batches.remove(batches.length - 1)]);
    expect(batchCount(), 5);

    found =
        mutationQueue.getAllMutationBatchesThroughBatchId(last.batchId);
    expect(found, batches);
    expect(found.length, 5);

    await testCase.removeMutationBatches(<MutationBatch>[batches.remove(3)]);
    expect(batchCount(), 4);

    await testCase.removeMutationBatches(<MutationBatch>[batches.remove(1)]);
    expect(batchCount(), 3);

    found =
        mutationQueue.getAllMutationBatchesThroughBatchId(last.batchId);
    expect(found, batches);
    expect(found.length, 3);

    await testCase.removeMutationBatches(
        <MutationBatch>[batches.toArray(new MutationBatch[0])]);
    found =
        mutationQueue.getAllMutationBatchesThroughBatchId(last.batchId);
    expect(found, emptyList());
    expect(found.length, 0);
    assertTrue(mutationQueue.isEmpty());
  });


  test('testStreamToken', () async {
    ByteString streamToken1 = streamToken('token1');
    ByteString streamToken2 = streamToken('token2');

    await testCase.persistence.runTransaction(
        'initial stream token', () =>
        mutationQueue.setLastStreamToken(streamToken1));

    MutationBatch batch1 = await testCase.addMutationBatch();
    addMutationBatch();

    expect(mutationQueue.getLastStreamToken(), streamToken1);

    await testCase.persistence.runTransaction(
        'acknowledgeBatchId', () =>
        mutationQueue.acknowledgeBatch(batch1, streamToken2));

    expect(mutationQueue.highestAcknowledgedBatchId, batch1.batchId);
    expect(mutationQueue.getLastStreamToken(), streamToken2);
  });*/
}
