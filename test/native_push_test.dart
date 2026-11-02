import 'package:flutter_test/flutter_test.dart';
import 'package:hermetica/src/native_push.dart' show pushChannel;

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeServer server;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var reply = <String, Object?>{'token': 'fcm-1', 'vendor': 'fcm', 'environment': 'debug', 'enablementStatus': 'DENIED', 'background': 'RESTRICTED'};
  final asked = <Object?>[];

  setUp(() {
    server = FakeServer();
    asked.clear();
    messenger.setMockMethodCallHandler(pushChannel, (c) async {
      asked.add(c.arguments);
      return reply;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(pushChannel, null));

  test('registers the token the native plugin read, with what the OS allows', () async {
    final hm = await server.start(prefs: {'hm_aid': 'anon-1'});
    expect(await hm.registerNativePushToken(requestPermission: true), isTrue);
    expect(asked.single, {'requestPermission': true});
    final a = (server.body(server.to('/client/push-tokens').single)['data'] as Map)['attributes'] as Map;
    expect([a['token'], a['vendor'], a['enablement_status'], a['background']], ['fcm-1', 'fcm', 'DENIED', 'RESTRICTED']);
    expect((a['device_metadata'] as Map)['environment'], 'debug');

    // Same token and permission: nothing new to send.
    expect(await hm.registerNativePushToken(), isTrue);
    expect(server.to('/client/push-tokens'), hasLength(1));

    // The user allowed notifications in settings: sent again.
    reply = {...reply, 'enablementStatus': 'AUTHORIZED'};
    expect(await hm.registerNativePushToken(), isTrue);
    expect(server.to('/client/push-tokens'), hasLength(2));

    expect(await hm.unregisterNativePushToken(), isTrue);
    expect(server.to('/client/push-token-unregister'), hasLength(1));
    hm.dispose();
  });

  test('false without a token, or where the plugin does not exist', () async {
    final hm = await server.start();
    messenger.setMockMethodCallHandler(pushChannel, (c) async => null);
    expect(await hm.registerNativePushToken(), isFalse);
    messenger.setMockMethodCallHandler(pushChannel, null); // MissingPluginException
    expect(await hm.registerNativePushToken(), isFalse);
    expect(server.to('/client/push-tokens'), isEmpty);
    hm.dispose();
  });
}
