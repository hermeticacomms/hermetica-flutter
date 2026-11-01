import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermetica/hermetica.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeServer server;
  late Hermetica hm;

  setUp(() => server = FakeServer());
  tearDown(() => hm.dispose());

  group('events', () {
    test('batches tracked events with one anonymous id, auth and an idempotency key', () async {
      hm = await server.start(maxBatchSize: 2);
      hm.track('viewed', properties: {'sku': 'A1'});
      expect(server.requests, isEmpty);
      hm.track('purchase', value: 1999, currency: 'USD');
      await hm.flush();

      final batches = server.to('/ingest/v1/batch');
      expect(batches, hasLength(1));
      final r = batches.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://api.test/ingest/v1/batch');
      expect(r.headers['authorization'], 'Bearer pk_test');
      expect(r.headers['idempotency-key'], isNotEmpty);
      final body = server.body(r);
      expect(body['consent'], {'analytics': true, 'marketing': true});
      final events = server.events();
      expect(events.map((e) => e['name']), ['viewed', 'purchase']);
      expect(events.map((e) => e['anonymousId']).toSet(), {hm.anonymousId});
      expect(events[0]['properties'], {'sku': 'A1', 'hm_sdk': 'flutter-$sdkVersion'});
      expect(events[1]['value'], 1999);
      expect(events[1]['currency'], 'USD');
      expect(events[0]['dedupeKey'], isNot(events[1]['dedupeKey']));
    });

    test('flushes when the app is paused', () async {
      hm = await server.start();
      hm.screen('cart');
      expect(server.requests, isEmpty);
      hm.didChangeAppLifecycleState(AppLifecycleState.paused);
      await hm.flush();
      expect(server.events().single['properties'], containsPair('screen', 'cart'));
    });

    test('keeps events queued on disk while sending fails, with one idempotency key per batch', () async {
      hm = await server.start();
      server.status = 503;
      hm.track('offline');
      await hm.flush();
      final tries = server.to('/ingest/v1/batch');
      expect(tries, hasLength(5));
      expect(tries.map((r) => r.headers['idempotency-key']).toSet(), hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('hm_queue'), contains('offline'));

      server.requests.clear();
      server.status = 200;
      await hm.flush();
      expect(server.events().single['name'], 'offline');
      expect(jsonDecode(prefs.getString('hm_queue')!), isEmpty);
    });

    test('sends events left from the last run', () async {
      final left = {'name': 'left', 'properties': <String, Object?>{}, 'dedupeKey': 'd1', 'anonymousId': 'a1'};
      hm = await server.start(prefs: {'hm_queue': jsonEncode([left])});
      await hm.flush();
      expect(server.events().single['dedupeKey'], 'd1');
    });

    test('drops a 4xx batch instead of retrying it', () async {
      hm = await server.start();
      server.status = 400;
      hm.track('bad');
      await hm.flush();
      await hm.flush();
      expect(server.to('/ingest/v1/batch'), hasLength(1));
    });
  });

  group('anonymous id', () {
    test('is created once and persisted', () async {
      hm = await server.start();
      final id = hm.anonymousId;
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(hm.anonymousId, id);
      expect((await SharedPreferences.getInstance()).getString('hm_aid'), id);
    });

    test('is read back on the next launch', () async {
      hm = await server.start(prefs: {'hm_aid': 'kept-id'});
      expect(hm.anonymousId, 'kept-id');
    });
  });

  group('tracking opt-out', () {
    test('drops queued events and sends nothing', () async {
      hm = await server.start();
      hm.track('before');
      await hm.setTrackingOptOut(true);
      hm.track('after');
      hm.identify(externalId: 'u1');
      hm.reportGeofenceEvent(GeofenceTransition.enter, 'g1');
      await hm.flush();
      expect(hm.anonymousId, isNull);
      expect(hm.trackingOptedOut, isTrue);
      expect(server.requests, isEmpty);
    });

    test('is remembered and can start on', () async {
      hm = await server.start(prefs: {'hm_opt_out': true});
      expect(hm.trackingOptedOut, isTrue);
      hm = await server.start(optOutByDefault: true);
      expect(hm.trackingOptedOut, isTrue);
      await hm.setTrackingOptOut(false);
      hm.track('back');
      await hm.flush();
      expect(server.events().single['name'], 'back');
    });
  });

  group('identify', () {
    test('links the anonymous id to the profile and sets attributes', () async {
      hm = await server.start();
      hm.identify(externalId: 'u1', email: 'a@b.co', traits: {'plan': 'pro'});
      hm.setProfileAttributes({'first_name': 'Ada'});
      await hm.flush();
      final sent = server.to('/ingest/v1/identify').map(server.body).toList();
      expect(sent, hasLength(2));
      expect(sent[0], {
        'anonymousId': hm.anonymousId,
        'identifiers': {'externalId': 'u1', 'email': 'a@b.co'},
        'traits': {'plan': 'pro'},
        'consent': {'analytics': true, 'marketing': true},
      });
      expect(sent[1]['traits'], {'first_name': 'Ada'});
      expect(sent[1]['identifiers'], {'externalId': 'u1', 'email': 'a@b.co'});
    });

    test('reset forgets the profile and starts a new anonymous id', () async {
      hm = await server.start();
      hm.identify(email: 'a@b.co');
      final before = hm.anonymousId;
      await hm.reset();
      expect(hm.anonymousId, isNot(before));
      hm.setProfileAttributes({'x': 1}); // nobody to attach it to
      await hm.flush();
      expect(server.to('/ingest/v1/identify'), hasLength(1));
    });
  });

  group('push', () {
    test('registers the token with the push-token JSON:API body', () async {
      hm = await server.start(prefs: {'hm_aid': 'anon-1'});
      hm.identify(email: 'a@b.co');
      expect(await hm.registerPushToken('tok', const PushOptions(vendor: PushVendor.apns)), isTrue);
      final r = server.to('/client/push-tokens').single;
      expect(r.url.queryParameters, {'company_id': 'pk_test'});
      expect(r.headers['idempotency-key'], isNotEmpty);
      expect(server.body(r), {
        'data': {
          'type': 'push-token',
          'attributes': {
            'token': 'tok',
            'platform': 'ios',
            'vendor': 'apns',
            'enablement_status': 'AUTHORIZED',
            'background': 'AVAILABLE',
            'device_metadata': {
              'device_id': 'anon-1',
              'sdk_version': 'flutter-$sdkVersion',
              'device_model': 'iPhone15,2',
              'os_name': 'ios',
              'os_version': '17.4',
              'app_name': 'shop',
              'app_version': '1.2.3',
              'app_build': '',
              'app_id': '',
              'environment': 'release',
            },
            'profile': {
              'data': {
                'type': 'profile',
                'attributes': {'email': 'a@b.co', 'anonymous_id': 'anon-1'},
              },
            },
          },
        },
      });
    });

    test('unregisters with the same envelope', () async {
      hm = await server.start();
      server.status = 400;
      expect(await hm.unregisterPushToken('tok', const PushOptions(vendor: PushVendor.fcm, platform: 'android')), isFalse);
      final data = server.body(server.to('/client/push-token-unregister').single)['data'] as Map<String, Object?>;
      expect(data['type'], 'push-token-unregister');
      expect((data['attributes'] as Map)['vendor'], 'fcm');
      expect((data['attributes'] as Map)['platform'], 'android');
    });

    test('tracks opens and hands the deep link to the callback', () async {
      hm = await server.start();
      final links = <String>[];
      hm.onDeepLink = links.add;
      expect(hm.handlePushOpened({'hermetica_message_id': 'm1', 'deep_link': 'shop://cart'}), 'shop://cart');
      expect(hm.handlePushOpened({'notification': {'request': {'content': {'data': {'hermetica_message_id': 'm2', 'url': 'https://x.test'}}}}}), 'https://x.test');
      expect(hm.handlePushOpened({'userInfo': {'hermetica_message_id': 'm3'}}), isNull);
      expect(hm.handlePushOpened({'other': 1}), isNull);
      await hm.flush();
      expect(links, ['shop://cart', 'https://x.test']);
      expect(server.events().map((e) => [e['name'], (e['properties'] as Map)['hermetica_message_id']]), [
        [r'$opened_push', 'm1'],
        [r'$opened_push', 'm2'],
        [r'$opened_push', 'm3'],
      ]);
    });
  });

  group('in-app', () {
    test('fetches messages for the trigger and the visitor', () async {
      hm = await server.start(prefs: {'hm_aid': 'anon-1'});
      server.reply = (r) => r.url.path == '/client/in-app-messages' ? {'items': [messageJson()]} : {'ok': true};
      final items = await hm.fetchInAppMessages(const InAppTrigger.event('added_to_cart', {'sku': 'A1'}));
      final q = server.to('/client/in-app-messages').single.url.queryParameters;
      expect(q, {
        'company_id': 'pk_test',
        'platform': 'ios',
        'trigger': 'event',
        'session_id': hm.sessionId,
        'name': 'added_to_cart',
        'properties': '{"sku":"A1"}',
        'anonymous_id': 'anon-1',
      });
      final m = items.single;
      expect([m.id, m.variant, m.layout, m.priority], ['m-1', 'b', 'modal', 1]);
      expect(m.blocks.map((b) => b.type), ['heading', 'text', 'buttons']);
      expect(m.blocks[2].buttons.first.value, 'shop://sale');
      expect(m.style.dismissible, isTrue);
    });

    test('is empty when the server fails', () async {
      hm = await server.start();
      server.status = 500;
      expect(await hm.fetchInAppMessages(const InAppTrigger.appOpen()), isEmpty);
    });

    test('reports impressions with the session and profile', () async {
      hm = await server.start(prefs: {'hm_aid': 'anon-1'});
      hm.identify(externalId: 'u1');
      await hm.reportInAppEvent(InAppMessage.fromJson(messageJson()), 'impression');
      final r = server.to('/client/in-app-events').single;
      expect(r.headers['idempotency-key'], isNotEmpty);
      expect(server.body(r), {
        'events': [
          {'messageId': 'm-1', 'variant': 'b', 'type': 'impression', 'platform': 'ios', 'sessionId': hm.sessionId},
        ],
        'profile': {'externalId': 'u1', 'anonymousId': 'anon-1'},
      });
    });
  });

  group('geofences', () {
    test('reads the JSON:API list and reports transitions as events', () async {
      hm = await server.start();
      server.reply = (r) => {
            'data': [
              {'type': 'geofence', 'id': 'g1', 'attributes': {'name': 'Store', 'latitude': 1, 'longitude': 2.5, 'radius': 150}},
            ],
          };
      final fences = await hm.getGeofences();
      expect(server.to('/client/geofences').single.url.queryParameters, {'company_id': 'pk_test'});
      final g = fences.single;
      expect([g.id, g.name, g.latitude, g.longitude, g.radius], ['g1', 'Store', 1.0, 2.5, 150.0]);

      hm.reportGeofenceEvent(GeofenceTransition.enter, 'g1');
      hm.reportGeofenceEvent(GeofenceTransition.exit, 'g1');
      await hm.flush();
      expect(server.events().map((e) => [e['name'], (e['properties'] as Map)['geofence_id']]), [
        [r'$geofence_enter', 'g1'],
        [r'$geofence_exit', 'g1'],
      ]);
    });
  });
}
