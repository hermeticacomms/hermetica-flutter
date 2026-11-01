import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermetica/hermetica.dart';
import 'package:hermetica/src/host.dart' show hexColor;

import 'support.dart';

void main() {
  late FakeServer server;

  Future<Hermetica> start(WidgetTester tester, Map<String, Object?> message) async {
    server = FakeServer()..reply = (r) => r.url.path == '/client/in-app-messages' ? {'items': [message]} : {'ok': true};
    return (await tester.runAsync(() => server.start(prefs: {'hm_aid': 'anon-1'})))!;
  }

  Widget app(Hermetica hm, {InAppMessageBuilder? builder, InAppActionHandler? onAction}) => MaterialApp(
        builder: (context, child) => HermeticaInAppHost(client: hm, builder: builder, onAction: onAction, child: child!),
        home: const Scaffold(body: Text('home')),
      );

  List<String> inAppEvents() => [
        for (final r in server.to('/client/in-app-events'))
          for (final e in server.body(r)['events'] as List) '${(e as Map)['type']}${e['button'] == null ? '' : ':${e['button']}'}',
      ];

  testWidgets('shows a modal, reports the impression, and routes a deep link button', (tester) async {
    final hm = await start(tester, messageJson());
    final links = <String>[];
    hm.onDeepLink = links.add;
    await tester.pumpWidget(app(hm));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(find.text('Big sale'), findsOneWidget);
    expect(find.text('Everything is 20% off.'), findsOneWidget);
    expect(server.to('/client/in-app-messages').single.url.queryParameters['trigger'], 'app_open');
    expect(inAppEvents(), ['impression']);

    await tester.tap(find.text('Shop'));
    await tester.pumpAndSettle();
    expect(find.text('Big sale'), findsNothing);
    expect(inAppEvents(), ['impression', 'click:Shop']);
    expect(links, ['shop://sale']);
    hm.dispose();
  });

  testWidgets('the close button reports a dismissal', (tester) async {
    final hm = await start(tester, messageJson(layout: 'banner_bottom'));
    await tester.pumpWidget(app(hm));
    await tester.pumpAndSettle();
    expect(find.text('Big sale'), findsOneWidget);

    await tester.tap(find.text('×'));
    await tester.pumpAndSettle();
    expect(find.text('Big sale'), findsNothing);
    expect(inAppEvents(), ['impression', 'dismiss']);
    hm.dispose();
  });

  testWidgets('shows each message once, and fetches again on a screen trigger', (tester) async {
    final hm = await start(tester, messageJson());
    await tester.pumpWidget(app(hm));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    hm.screen('cart');
    await tester.pumpAndSettle();
    expect(server.to('/client/in-app-messages').last.url.queryParameters, containsPair('trigger', 'screen_view'));
    expect(find.text('Big sale'), findsNothing); // same message id: not shown again
    expect(inAppEvents(), ['impression', 'click:Later']);
    hm.dispose();
  });

  testWidgets('a builder renders the message, and onAction can take over buttons', (tester) async {
    final hm = await start(tester, messageJson());
    final handled = <String>[];
    final links = <String>[];
    hm.onDeepLink = links.add;
    await tester.pumpWidget(app(
      hm,
      builder: (context, m, onButton, onDismiss) => Center(
        child: TextButton(onPressed: () => onButton(m.blocks[2].buttons.first), child: Text('custom ${m.id}')),
      ),
      onAction: (action, value, m) {
        handled.add('$action $value');
        return true;
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('Big sale'), findsNothing);

    await tester.tap(find.text('custom m-1'));
    await tester.pumpAndSettle();
    expect(find.text('custom m-1'), findsNothing);
    expect(handled, ['deep_link shop://sale']);
    expect(links, isEmpty);
    expect(inAppEvents(), ['impression', 'click:Shop']);
    hm.dispose();
  });

  test('hexColor reads CSS hex', () {
    const fallback = Color(0xff000000);
    expect(hexColor('#2563eb', fallback), const Color(0xff2563eb));
    expect(hexColor('#fff', fallback), const Color(0xffffffff));
    expect(hexColor('#11223380', fallback), const Color(0x80112233));
    expect(hexColor('nope', fallback), fallback);
  });
}
