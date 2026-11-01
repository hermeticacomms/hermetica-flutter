import 'package:flutter/material.dart';
import 'package:hermetica/hermetica.dart';

Future<void> main() async {
  final hm = await Hermetica.initialize('pk_your_site_key', 'https://api.example.com');
  hm.onDeepLink = (link) => debugPrint('open $link'); // route it with your router or url_launcher
  hm.identify(externalId: 'user-42', email: 'ada@example.com', traits: {'plan': 'pro'});

  // Push: get the token from firebase_messaging (or APNs) and hand it over.
  //   final token = await FirebaseMessaging.instance.getToken();
  //   await hm.registerPushToken(token!, const PushOptions(vendor: PushVendor.fcm));
  //   FirebaseMessaging.onMessageOpenedApp.listen((m) => hm.handlePushOpened(m.data));

  // Geofences: register these with your geofencing plugin and report its transitions.
  //   for (final g in await hm.getGeofences()) { /* plugin.add(g.id, g.latitude, g.longitude, g.radius) */ }
  //   plugin.onEnter((id) => hm.reportGeofenceEvent(GeofenceTransition.enter, id));

  runApp(const ShopApp());
}

class ShopApp extends StatelessWidget {
  const ShopApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        builder: (context, child) => HermeticaInAppHost(child: child!),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Shop')),
        body: Center(
          child: FilledButton(
            onPressed: () => Hermetica.instance.track('added_to_cart', properties: {'sku': 'A1'}, value: 1999, currency: 'USD'),
            child: const Text('Add to cart'),
          ),
        ),
      );
}
