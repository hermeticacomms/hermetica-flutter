import 'dart:convert';

import 'package:hermetica/hermetica.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake Hermetica server: records every request and answers with [status] and [reply].
class FakeServer {
  final requests = <http.Request>[];
  int status = 200;
  Object? Function(http.Request r) reply = (_) => {'ok': true};

  late final client = MockClient((r) async {
    requests.add(r);
    return http.Response(jsonEncode(reply(r)), status, headers: {'content-type': 'application/json'});
  });

  List<http.Request> to(String path) => requests.where((r) => r.url.path == path).toList();
  Map<String, Object?> body(http.Request r) => jsonDecode(r.body) as Map<String, Object?>;
  List<Map<String, Object?>> events() => [for (final r in to('/ingest/v1/batch')) ...(body(r)['events'] as List).cast<Map<String, Object?>>()];

  Future<Hermetica> start({Map<String, Object> prefs = const {}, int maxBatchSize = 20, bool optOutByDefault = false}) {
    SharedPreferences.setMockInitialValues(prefs);
    return Hermetica.initialize(
      'pk_test',
      'https://api.test/',
      httpClient: client,
      platform: 'ios',
      device: const DeviceMetadata(appName: 'shop', appVersion: '1.2.3', deviceModel: 'iPhone15,2', osVersion: '17.4'),
      maxBatchSize: maxBatchSize,
      trackingOptOutByDefault: optOutByDefault,
      retryBaseDelay: Duration.zero,
    );
  }
}

/// A message as the server sends it.
Map<String, Object?> messageJson({String id = 'm-1', String layout = 'modal'}) => {
      'id': id,
      'variant': 'b',
      'layout': layout,
      'queued': false,
      'priority': 1,
      'content': {
        'blocks': [
          {'type': 'heading', 'text': 'Big sale'},
          {'type': 'text', 'text': 'Everything is 20% off.'},
          {
            'type': 'buttons',
            'buttons': [
              {'label': 'Shop', 'action': 'deep_link', 'value': 'shop://sale', 'style': 'primary'},
              {'label': 'Later', 'action': 'dismiss', 'style': 'secondary'},
            ],
          },
        ],
      },
      'style': {'background': '#ffffff', 'textColor': '#111', 'accentColor': '#2563eb', 'radius': 12, 'dismissible': true},
    };
