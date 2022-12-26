import 'dart:async';

import 'package:firedart/generated/google/firestore/v1/common.pb.dart';
import 'package:firedart/generated/google/firestore/v1/document.pb.dart' as pb;
import 'package:firedart/generated/google/firestore/v1/firestore.pbgrpc.dart';
import 'package:firedart/generated/google/firestore/v1/query.pb.dart';
import 'package:firedart/generated/google/firestore/v1/write.pb.dart' as pb;
import 'package:grpc/grpc.dart';

import 'authenticators.dart';
import 'models.dart';

typedef ErrorHandler = void Function(Object, StackTrace);

class _FirestoreGatewayStreamCache {
  void Function(String userInfo)? onDone;
  String userInfo;
  ErrorHandler onError;

  StreamController<ListenRequest>? _listenRequestStreamController;
  late StreamController<ListenResponse> _listenResponseStreamController;
  late Map<String, Document> _documentMap;

  late bool _shouldCleanup;

  Stream<ListenResponse> get stream => _listenResponseStreamController.stream;

  Map<String, Document> get documentMap => _documentMap;

  _FirestoreGatewayStreamCache({
    this.onDone,
    required this.userInfo,
    ErrorHandler? onError,
  }) : onError = onError ?? _handleErrorStub;

  void setListenRequest(
    ListenRequest request,
    FirestoreClient client,
    String database,
  ) {
    // Close the request stream if this function is called for a second time;
    _listenRequestStreamController?.close();

    _documentMap = <String, Document>{};

    _listenRequestStreamController = StreamController<ListenRequest>();

    _listenResponseStreamController =
        StreamController<ListenResponse>.broadcast(
      onListen: _handleListenOnResponseStream,
      onCancel: _handleCancelOnResponseStream,
    );

    _listenResponseStreamController.addStream(client
        .listen(
          _listenRequestStreamController!.stream,
          options: CallOptions(
            metadata: {'google-cloud-resource-prefix': database},
          ),
        )
        .handleError(onError));

    _listenRequestStreamController!.add(request);
  }

  void _handleListenOnResponseStream() {
    _shouldCleanup = false;
  }

  void _handleCancelOnResponseStream() {
    // Clean this up in the future
    _shouldCleanup = true;
    Future.microtask(_handleDone);
  }

  void _handleDone() {
    if (!_shouldCleanup) {
      return;
    }
    onDone?.call(userInfo);
    // Clean up stream resources
    _listenRequestStreamController!.close();
  }

  static void _handleErrorStub(e, trace) {
    throw e;
  }
}

class FirestoreGateway {
  final Authenticator authenticator;
  final String database;
  final String documentsRoot;
  final ErrorHandler? onError;

  final Map<String, _FirestoreGatewayStreamCache> _listenRequestStreamMap;

  late FirestoreClient _client;

  FirestoreGateway({
    required this.authenticator,
    required String projectId,
    String? databaseId,
    this.onError,
  })  : database = "projects/$projectId/databases/${databaseId ?? '(default)'}",
        documentsRoot =
            'projects/$projectId/databases/${databaseId ?? '(default)'}/documents',
        _listenRequestStreamMap = <String, _FirestoreGatewayStreamCache>{} {
    _setupClient();
  }

  Future<Page<Document>> getCollection(
    String path,
    int pageSize,
    String nextPageToken,
  ) async {
    final request = ListDocumentsRequest()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..collectionId = path.substring(path.lastIndexOf('/') + 1)
      ..pageSize = pageSize
      ..pageToken = nextPageToken;

    final response =
        await _client.listDocuments(request).catchError(_handleError);

    final documents =
        response.documents.map((rawDocument) => Document(this, rawDocument));

    return Page(documents, response.nextPageToken);
  }

  Stream<List<Document>> streamCollection(String path) {
    if (_listenRequestStreamMap.containsKey(path)) {
      return _mapCollectionStream(_listenRequestStreamMap[path]!);
    }

    final selector = StructuredQuery_CollectionSelector()
      ..collectionId = path.substring(path.lastIndexOf('/') + 1);

    final query = StructuredQuery()..from.add(selector);

    final queryTarget = Target_QueryTarget()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..structuredQuery = query;

    final target = Target()..query = queryTarget;

    final request = ListenRequest()
      ..database = documentsRoot
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(
      onDone: _handleDone,
      userInfo: path,
      onError: _handleError,
    );

    _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, documentsRoot);

    return _mapCollectionStream(listenRequestStream);
  }

  Future<Document> createDocument(
    String path,
    String? documentId,
    pb.Document document,
  ) async {
    final split = path.split('/');
    final parent = split.sublist(0, split.length - 1).join('/');
    final collectionId = split.last;

    final request = CreateDocumentRequest()
      ..parent = parent
      ..collectionId = collectionId
      ..documentId = documentId ?? ''
      ..document = document;

    final response =
        await _client.createDocument(request).catchError(_handleError);

    return Document(this, response);
  }

  Future<Document> getDocument(path) async {
    final rawDocument = await _client
        .getDocument(GetDocumentRequest()..name = path)
        .catchError(_handleError);

    return Document(this, rawDocument);
  }

  Future<void> updateDocument(
    String path,
    pb.Document document,
    bool update,
  ) {
    document.name = path;

    final request = UpdateDocumentRequest()..document = document;

    if (update) {
      final mask = DocumentMask();
      document.fields.keys.forEach((key) => mask.fieldPaths.add(key));
      request.updateMask = mask;
    }

    return _client.updateDocument(request).catchError(_handleError);
  }

  Future<void> deleteDocument(String path) => _client
      .deleteDocument(DeleteDocumentRequest()..name = path)
      .catchError(_handleError);

  Future<List<WriteResult>?> commit(List<pb.Write> writes) async {
    try {
      final resp = await _client
          .commit(CommitRequest(database: database, writes: writes));

      final writeResults = <WriteResult>[];

      for (final writeResult in resp.writeResults) {
        writeResults.add(WriteResult(writeResult.updateTime.toDateTime()));
      }

      return writeResults;
    } catch (e, trace) {
      _handleError(e, trace);
    }

    return null;
  }

  Stream<Document?> streamDocument(String path) {
    if (_listenRequestStreamMap.containsKey(path)) {
      return _mapDocumentStream(_listenRequestStreamMap[path]!);
    }

    final documentsTarget = Target_DocumentsTarget()..documents.add(path);
    final target = Target()..documents = documentsTarget;
    final request = ListenRequest()
      ..database = documentsRoot
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(
      onDone: _handleDone,
      userInfo: path,
      onError: _handleError,
    );

    _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, documentsRoot);

    return _mapDocumentStream(listenRequestStream);
  }

  Future<List<Document>> runQuery(
    StructuredQuery structuredQuery,
    String fullPath,
  ) {
    final runQuery = RunQueryRequest()
      ..structuredQuery = structuredQuery
      ..parent = fullPath.substring(0, fullPath.lastIndexOf('/'));

    final response = _client.runQuery(runQuery);

    return response
        .where((event) => event.hasDocument())
        .map((event) => Document(this, event.document))
        .toList();
  }

  void _setupClient() {
    _listenRequestStreamMap.clear();
    _client = FirestoreClient(ClientChannel('firestore.googleapis.com'),
        options: authenticator.toCallOptions);
  }

  void _handleError(e, trace) {
    if (e is GrpcError &&
        [
          StatusCode.unknown,
          StatusCode.unimplemented,
          StatusCode.internal,
          StatusCode.unavailable,
          StatusCode.unauthenticated,
          StatusCode.dataLoss,
        ].contains(e.code)) {
      _setupClient();
    }

    if (onError != null) {
      onError!(e, trace);
    } else {
      throw e;
    }
  }

  void _handleDone(String path) => _listenRequestStreamMap.remove(path);

  Stream<List<Document>> _mapCollectionStream(
    _FirestoreGatewayStreamCache listenRequestStream,
  ) =>
      listenRequestStream.stream
          .where((response) =>
              response.hasDocumentChange() ||
              response.hasDocumentRemove() ||
              response.hasDocumentDelete())
          .map((response) {
        if (response.hasDocumentChange()) {
          listenRequestStream
                  .documentMap[response.documentChange.document.name] =
              Document(this, response.documentChange.document);
        } else {
          listenRequestStream.documentMap
              .remove(response.documentDelete.document);
        }

        return listenRequestStream.documentMap.values.toList();
      });

  Stream<Document?> _mapDocumentStream(
    _FirestoreGatewayStreamCache listenRequestStream,
  ) =>
      listenRequestStream.stream
          .where((response) =>
              response.hasDocumentChange() ||
              response.hasDocumentRemove() ||
              response.hasDocumentDelete())
          .map((response) => response.hasDocumentChange()
              ? Document(this, response.documentChange.document)
              : null);
}
