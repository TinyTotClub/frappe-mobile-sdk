import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  Map<String, dynamic> loginResponse() => {
    'message': 'Logged In',
    'user': 'firebase.user@example.com',
    'full_name': 'Firebase User',
    'language': 'en',
    'access_token': 'gAAAA-firebase-access',
    'refresh_token': 'firebase-refresh',
    'offline_enabled': false,
    'mobile_form_names': <dynamic>[],
    'roles': ['Mobile User', 'LMS Student'],
    'permissions': <dynamic>[],
  };

  test(
    'loginWithFirebase exchanges id_token, persists token pair, sets bearer',
    () async {
      http.Request? captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode(loginResponse()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = FrappeClient('https://x.test', httpClient: mock);
      final auth = AuthService.forTesting(client, database: db);

      final response = await auth.loginWithFirebase('firebase-id-token');

      // Request went to the bridge endpoint with the id_token arg.
      expect(
        captured!.url.toString(),
        'https://x.test/api/method/mobile_auth.login_with_firebase',
      );
      expect(jsonDecode(captured!.body), {'id_token': 'firebase-id-token'});

      // Same post-conditions as a password login.
      expect(response['user'], 'firebase.user@example.com');
      expect(auth.isAuthenticated, isTrue);
      expect(auth.roles, containsAll(['Mobile User', 'LMS Student']));
      expect(auth.language, 'en');
      expect(auth.currentAccessToken, 'gAAAA-firebase-access');

      final stored = await db.authTokenDao.getCurrentToken();
      expect(stored, isNotNull);
      expect(stored!.accessToken, 'gAAAA-firebase-access');
      expect(stored.refreshToken, 'firebase-refresh');
      expect(stored.user, 'firebase.user@example.com');
    },
  );

  test('loginWithFirebase throws when access_token is missing', () async {
    final mock = MockClient((req) async {
      final body = loginResponse()..remove('access_token');
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final client = FrappeClient('https://x.test', httpClient: mock);
    final auth = AuthService.forTesting(client, database: db);

    await expectLater(
      auth.loginWithFirebase('firebase-id-token'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('missing access_token'),
        ),
      ),
    );
    expect(auth.isAuthenticated, isFalse);
  });

  test('loginWithFirebase surfaces server auth failure', () async {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode({'exc_type': 'AuthenticationError'}),
        401,
        headers: {'content-type': 'application/json'},
      ),
    );

    final client = FrappeClient('https://x.test', httpClient: mock);
    final auth = AuthService.forTesting(client, database: db);

    await expectLater(
      auth.loginWithFirebase('bad-token'),
      throwsA(isA<Exception>()),
    );
    expect(auth.isAuthenticated, isFalse);
    expect(await db.authTokenDao.getCurrentToken(), isNull);
  });
}
