# Hermetica for Flutter

Track events, identify users, register push tokens, show in-app messages and report geofence events from a Flutter app.
Mostly Dart: the only native code reads the push token (FCM on Android, APNs on iOS). Geofence transitions come from
the geofencing plugin you already use and are handed to the SDK.

```yaml
dependencies:
  hermetica: ^0.1.0
```

## Start

```dart
import 'package:hermetica/hermetica.dart';

Future<void> main() async {
  final hm = await Hermetica.initialize('pk_your_site_key', 'https://api.example.com');
  hm.onDeepLink = (link) => router.go(link); // push and in-app deep links
  runApp(const MyApp());
}
```

Use the public site key (never a secret `hm_sk_` key in an app). After `initialize`, the client is also `Hermetica.instance`.

## Events and profiles

```dart
hm.track('added_to_cart', properties: {'sku': 'A1'}, value: 1999, currency: 'USD'); // value in cents
hm.screen('cart');
hm.identify(externalId: 'user-42', email: 'ada@example.com', traits: {'plan': 'pro'});
hm.setProfileAttributes({'first_name': 'Ada'});
await hm.reset(); // on logout: forgets the profile, starts a new anonymous id
```

- Each install gets a persisted anonymous id (`hm.anonymousId`); `identify` links it to the profile.
- Events are queued on the device, sent in batches (20 by default, or every 2 seconds), retried with backoff while
  offline, and flushed when the app is paused. Call `hm.flush()` to send now.
- Every POST carries an `Idempotency-Key`; events carry a dedupe key, so retries never double count.

## Tracking opt-out

```dart
await hm.setTrackingOptOut(true);
```

While opted out, queued events are dropped, the anonymous id is forgotten, and nothing is tracked or sent (events,
identify, in-app impressions). The choice is stored on the device. If you must ask before tracking, start opted out:
`Hermetica.initialize(key, url, trackingOptOutByDefault: true)`, then `setTrackingOptOut(false)` once the user agrees.
Consent and suppression are also enforced by the server.

## Push

```dart
await hm.registerNativePushToken(requestPermission: true); // reads the token natively and registers it
```

The plugin reads the FCM token on Android (the app must include Firebase, e.g. firebase_messaging) and the APNs token on
iOS (enable the Push Notifications capability), with the OS permission and background state. It checks again on every
resume and re-registers only when the token or permission changed; `identify` and `reset` move it to the new profile.
`hm.unregisterNativePushToken()` stops it (logout). To hand a token in yourself instead:

```dart
final token = await FirebaseMessaging.instance.getToken();
await hm.registerPushToken(token!, const PushOptions(vendor: PushVendor.fcm));
// iOS with APNs tokens: PushOptions(vendor: PushVendor.apns, environment: PushEnvironment.debug) in debug builds.

FirebaseMessaging.onMessageOpenedApp.listen((m) => hm.handlePushOpened(m.data));
await hm.unregisterPushToken(token, const PushOptions(vendor: PushVendor.fcm)); // logout
```

`handlePushOpened` tracks the open for Hermetica messages and passes the notification's deep link to `onDeepLink`
(it also returns it). Fill `DeviceMetadata` (from device_info_plus / package_info_plus) in `initialize` to describe the
device. `enablementStatus` and `background` default to authorized/available; pass what the OS reports.

## In-app messages

```dart
MaterialApp(
  builder: (context, child) => HermeticaInAppHost(child: child!),
  home: const HomeScreen(),
);
```

The host asks for messages on start (`app_open`) and after every `screen` and `track`, shows the best one (modal,
top/bottom banner, bottom sheet or fullscreen, with image, heading, text and buttons), and reports impression, click
and dismiss. Targeting and frequency caps are applied by the server per session; the host shows each message once.

- Buttons: `deep_link` / `url` go to `onDeepLink`, `event` buttons track that event, `dismiss` closes.
- The Android back button closes the message on top and reports a dismissal, like closing a drawer; the screen
  behind stays. Predictive back works too: with `android:enableOnBackInvokedCallback="true"` on the `<application>`,
  the host tells Android that Flutter takes the gesture while a message shows, and hands it back after.
- `onAction: (action, value, message) => true` handles a button yourself (true skips the default).
- `builder: (context, message, onButton, onDismiss) => MyCard(...)` renders messages yourself; call `onButton` /
  `onDismiss` so the click or dismissal is reported.
- Without the widget: `hm.fetchInAppMessages(InAppTrigger.screenView('cart'))` and `hm.reportInAppEvent(m, 'impression')`.

## Geofences

```dart
for (final g in await hm.getGeofences()) {
  geofencing.add(id: g.id, latitude: g.latitude, longitude: g.longitude, radius: g.radius); // your plugin
}
geofencing.onEnter((id) => hm.reportGeofenceEvent(GeofenceTransition.enter, id));
geofencing.onExit((id) => hm.reportGeofenceEvent(GeofenceTransition.exit, id));
```

Transitions are sent as `$geofence_enter` / `$geofence_exit` / `$geofence_dwell` events, so journeys can start on them.

## License

MIT
