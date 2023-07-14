import 'package:firedart/auth/firebase_auth.dart';
import 'package:firedart/firestore/application_default_authenticator.dart';
import 'package:firedart/firestore/token_authenticator.dart';

import 'firestore_gateway.dart';
import 'models.dart';

class Emulator {
  Emulator(this.host, this.port);

  final String host;
  final int port;
}

class Firestore {
  /* Singleton interface */
  static Firestore? _instance;

  static Firestore initialize(
    String projectId, {
    bool useApplicationDefaultAuth = false,
    String? databaseId,
    Emulator? emulator,
    ErrorHandler? onError,
  }) {
    if (_instance != null) {
      throw Exception('Firestore instance was already initialized');
    }
    final RequestAuthenticator? authenticator;

    if (useApplicationDefaultAuth) {
      authenticator = ApplicationDefaultAuthenticator(
        useEmulator: emulator != null,
      ).authenticate;
    } else {
      FirebaseAuth? auth;
      try {
        auth = FirebaseAuth.instance;
      } catch (e) {
        // FirebaseAuth isn't initialized
      }

      authenticator = TokenAuthenticator.from(auth)?.authenticate;
    }

    _instance = Firestore(
      projectId,
      databaseId: databaseId,
      authenticator: authenticator,
      emulator: emulator,
      onError: onError,
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

  Firestore(
    String projectId, {
    String? databaseId,
    RequestAuthenticator? authenticator,
    Emulator? emulator,
    ErrorHandler? onError,
  })  : _gateway = FirestoreGateway(
          projectId,
          databaseId: databaseId,
          authenticator: authenticator,
          emulator: emulator,
          onError: onError,
        ),
        assert(projectId.isNotEmpty);

  Reference reference(String path) => Reference.create(_gateway, path);

  CollectionReference collection(String path) =>
      CollectionReference(_gateway, path);

  DocumentReference document(String path) => DocumentReference(_gateway, path);

  WriteBatch batch() => WriteBatch(_gateway);

  void close() {
    _gateway.close();
  }
}
