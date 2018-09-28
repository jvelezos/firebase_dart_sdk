// File created by
// Lung Razvan <long1eu>
// on 20/09/2018

import 'dart:async';

import 'package:firebase_database_collection/firebase_database_collection.dart';
import 'package:firebase_firestore/src/firebase/firestore/core/query.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/document.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/document_key.dart';
import 'package:firebase_firestore/src/firebase/firestore/model/maybe_document.dart';
import 'package:firebase_firestore/src/firebase/firestore/util/database_impl.dart';

/// Represents cached documents received from the remote backend.
///
/// * The cache is keyed by [DocumentKey] and entries in the cache are
/// [MaybeDocument] instances, meaning we can cache both [Document] instances
/// (an actual document with data) as well as [NoDocument] instances
/// (indicating that the document is known to not exist).
abstract class RemoteDocumentCache {
  /// Adds or replaces an entry in the cache.
  ///
  /// * The cache key is extracted from [MaybeDocument.key]. If there is already
  /// a cache entry for the key, it will be replaced.
  Future<void> add(DatabaseExecutor tx, MaybeDocument maybeDocument);

  /// Removes the cached entry for the given key (no-op if no entry exists).
  Future<void> remove(DatabaseExecutor tx, DocumentKey documentKey);

  /// Looks up an entry in the cache.
  ///
  /// The [documentKey] of the entry to look up. Returns the cached [Document] or
  /// [NoDocument] entry, or null if we have nothing cached.
  Future<MaybeDocument> get(DatabaseExecutor tx, DocumentKey documentKey);

  /// Executes a query against the cached Document entries
  ///
  /// * Implementations may return extra documents if convenient. The results
  /// should be re-filtered by the consumer before presenting them to the user.
  ///
  /// * Cached NoDocument entries have no bearing on query results.
  Future<ImmutableSortedMap<DocumentKey, Document>>
      getAllDocumentsMatchingQuery(DatabaseExecutor tx, Query query);
}
