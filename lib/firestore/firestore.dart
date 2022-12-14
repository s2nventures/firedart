import 'package:firedart/auth/firebase_auth.dart';
import 'package:firedart/firestore/authenticators.dart';

import 'firestore_gateway.dart';
import 'models.dart';

class Firestore {
  /* Singleton interface */
  static Firestore? _instance;

  static Firestore initialize(String projectId, {String? databaseId}) {
    if (_instance != null) {
      throw Exception('Firestore instance was already initialized');
    }

    late Authenticator authenticator;

    try {
      authenticator = TokenAuthenticator(FirebaseAuth.instance);
    } catch (e) {
      // FirebaseAuth isn't initialized
    }

    _instance = Firestore(
      authenticator: authenticator,
      projectId: projectId,
      databaseId: databaseId,
    );

    return _instance!;
  }

  static Firestore get instance {
    if (_instance == null) {
      throw Exception(
          "Firestore hasn't been initialized. Please call Firestore.initialize() before using it.");
    }

    return _instance!;
  }

  /* Instance interface */
  final FirestoreGateway _gateway;

  Firestore({
    required Authenticator authenticator,
    required String projectId,
    String? databaseId,
  })  : _gateway = FirestoreGateway(
          authenticator: authenticator,
          projectId: projectId,
          databaseId: databaseId,
        ),
        assert(projectId.isNotEmpty);

  Reference reference(String path) => Reference.create(_gateway, path);

  CollectionReference collection(String path) =>
      CollectionReference(_gateway, path);

  DocumentReference document(String path) => DocumentReference(_gateway, path);
}
