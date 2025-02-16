import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:grpc/grpc.dart';
import 'package:http/http.dart' as http;

abstract class Authenticator {
  Future<void> authenticate(Map<String, String> metadata, String uri);

  CallOptions get toCallOptions => CallOptions(providers: [authenticate]);
}

/// Authenticates with OAuth2 [AccessCredentials] using the service account
/// credentials json file as specified in the GOOGLE_APPLICATION_CREDENTIALS
/// environment variable.
class ServiceAccountAuthenticator extends Authenticator {
  static const _defaultScopes = [
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/datastore',
  ];

  static final clientCredentials = () {
    final googleAppCreds =
        Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'];

    if (googleAppCreds == null) {
      return null;
    }

    return ServiceAccountCredentials.fromJson(
        jsonDecode(File(googleAppCreds).readAsStringSync()));
  }();

  final List<String> scopes;

  ServiceAccountAuthenticator([List<String>? scopes])
      : scopes = scopes ?? _defaultScopes;

  @override
  Future<void> authenticate(Map<String, String> metadata, String uri) async {
    if (clientCredentials == null) {
      throw Exception(
          'GOOGLE_APPLICATION_CREDENTIALS environment variable must be set');
    }

    final credentials = await obtainAccessCredentialsViaServiceAccount(
      clientCredentials!,
      scopes,
      http.Client(),
    );

    metadata['authorization'] = 'Bearer ${credentials.accessToken.data}';
  }
}

/// Authenticates with OAuth2 [AccessCredentials] using the metadata API on
/// ComputeEngine.
class MetadataAuthenticator extends Authenticator {
  @override
  Future<void> authenticate(Map<String, String> metadata, String uri) async {
    final credentials =
        await obtainAccessCredentialsViaMetadataServer(http.Client());

    metadata['authorization'] = 'Bearer ${credentials.accessToken.data}';
  }
}
