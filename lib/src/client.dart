import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';
import 'push.dart';

const sdkVersion = '0.1.0';
const _serverMaxBatch = 50;
const _retryAfter = Duration(seconds: 30);
const _kAid = 'hm_aid', _kQueue = 'hm_queue', _kProfile = 'hm_profile', _kOptOut = 'hm_opt_out';

/// The Hermetica client. Call [Hermetica.initialize] once (after `WidgetsFlutterBinding.ensureInitialized()` is fine,
/// it calls that itself), then use [Hermetica.instance].
///
/// Events are queued on the device (shared_preferences), sent in batches, retried with backoff while offline, and
/// flushed when the app goes to the background.
class Hermetica with WidgetsBindingObserver {
  Hermetica._(this._api, this._prefs, this._ownsHttp, {required this.platform, required this.device, required int maxBatchSize, required this.flushInterval, required this.maxQueue})
      : maxBatchSize = min(maxBatchSize, _serverMaxBatch);

  static Hermetica? _instance;

  /// The client from the last [initialize].
  static Hermetica get instance => _instance ?? (throw StateError('Call Hermetica.initialize first'));

  /// [siteKey] is your public site key; [baseUrl] is your Hermetica API URL. [trackingOptOutByDefault] is the
  /// opt-out state on first launch (set it to true when you must ask before tracking); a later
  /// [setTrackingOptOut] is remembered. [retryBaseDelay] is the first backoff step (mainly for tests).
  static Future<Hermetica> initialize(
    String siteKey,
    String baseUrl, {
    http.Client? httpClient,
    DeviceMetadata device = const DeviceMetadata(),
    String? platform,
    bool trackingOptOutByDefault = false,
    int maxBatchSize = 20,
    Duration flushInterval = const Duration(seconds: 2),
    int maxQueue = 200,
    Duration retryBaseDelay = const Duration(milliseconds: 500),
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    _instance?.dispose();
    final prefs = await SharedPreferences.getInstance();
    final h = Hermetica._(
      Api(baseUrl, siteKey, httpClient ?? http.Client(), retryBase: retryBaseDelay),
      prefs,
      httpClient == null,
      platform: platform ?? (kIsWeb ? 'web' : defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios'),
      device: device,
      maxBatchSize: maxBatchSize,
      flushInterval: flushInterval,
      maxQueue: maxQueue,
    );
    h._load(trackingOptOutByDefault);
    WidgetsBinding.instance.addObserver(h);
    _instance = h;
    if (h._queue.isNotEmpty) unawaited(h.flush()); // events left from the last run
    return h;
  }

  final Api _api;
  final SharedPreferences _prefs;
  final bool _ownsHttp;

  /// `ios`, `android` or `web`.
  final String platform;
  final DeviceMetadata device;
  final int maxBatchSize;
  final Duration flushInterval;
  final int maxQueue;

  /// Sent with in-app requests so per-session frequency caps hold.
  final String sessionId = newUuid();

  /// Receives the deep link of a tapped push ([handlePushOpened]) or an in-app `deep_link` / `url` button. Open it
  /// with your router or url_launcher.
  void Function(String link)? onDeepLink;

  final _triggers = StreamController<InAppTrigger>.broadcast();
  List<Map<String, Object?>> _queue = [];
  Map<String, String> _profile = {};
  String? _aid;
  bool _optedOut = false;
  Timer? _timer;
  Future<void> _inflight = Future<void>.value();

  /// Moments that can show an in-app message (screens, events). [HermeticaInAppHost] listens to this.
  Stream<InAppTrigger> get triggers => _triggers.stream;

  T? _json<T>(String key) {
    try {
      final s = _prefs.getString(key);
      return s == null ? null : jsonDecode(s) as T;
    } catch (_) {
      return null;
    }
  }

  void _load(bool optOutDefault) {
    _optedOut = _prefs.getBool(_kOptOut) ?? optOutDefault;
    _aid = _optedOut ? null : _prefs.getString(_kAid);
    _queue = [for (final e in _json<List<Object?>>(_kQueue) ?? const []) if (e is Map<String, Object?>) e];
    _profile = {for (final e in (_json<Map<String, Object?>>(_kProfile) ?? const {}).entries) if (e.value is String) e.key: e.value as String};
  }

  void _save() => unawaited(_prefs.setString(_kQueue, jsonEncode(_queue)));

  Future<void> _chain(Future<void> Function() f) => _inflight = _inflight.then((_) => f()).catchError((Object e) => debugPrint('[hermetica] $e'));

  /// The persisted device id, or null while tracking is opted out.
  String? get anonymousId {
    if (_optedOut) return null;
    if (_aid == null) {
      _aid = newUuid();
      unawaited(_prefs.setString(_kAid, _aid!));
    }
    return _aid;
  }

  bool get trackingOptedOut => _optedOut;

  /// Opted out: queued events are dropped, the anonymous id is forgotten, and nothing is tracked or sent until
  /// opted back in. The choice is stored on the device.
  Future<void> setTrackingOptOut(bool optOut) async {
    _optedOut = optOut;
    await _prefs.setBool(_kOptOut, optOut);
    if (!optOut) return;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _aid = null;
    await _prefs.remove(_kQueue);
    await _prefs.remove(_kAid);
  }

  /// The profile keys as the client endpoints name them (only those that are set).
  Map<String, String> _keys() {
    final aid = anonymousId;
    return {
      if (_profile['email'] != null) 'email': _profile['email']!,
      if (_profile['phoneNumber'] != null) 'phone_number': _profile['phoneNumber']!,
      if (_profile['externalId'] != null) 'external_id': _profile['externalId']!,
      if (aid != null) 'anonymous_id': aid,
    };
  }

  /// Who this user is. Kept on the device for push and in-app targeting, and linked to the anonymous id on the server.
  void identify({String? externalId, String? email, String? phoneNumber, Map<String, Object?> traits = const {}}) {
    for (final (k, v) in [('externalId', externalId), ('email', email), ('phoneNumber', phoneNumber)]) {
      if (v != null && v.isNotEmpty) _profile[k] = v;
    }
    unawaited(_prefs.setString(_kProfile, jsonEncode(_profile)));
    _identify(traits);
  }

  /// Sets profile properties (first name, plan, ...). Needs a known profile: call [identify] first.
  void setProfileAttributes(Map<String, Object?> attributes) => _identify(attributes);

  void _identify(Map<String, Object?> traits) {
    final aid = anonymousId;
    final ids = {
      if (_profile['externalId'] != null) 'externalId': _profile['externalId'],
      if (_profile['email'] != null) 'email': _profile['email'],
      if (_profile['phoneNumber'] != null) 'phone': _profile['phoneNumber'],
    };
    if (aid == null || ids.isEmpty) return; // opted out, or nobody to attach the traits to
    final body = {'anonymousId': aid, 'identifiers': ids, 'traits': traits, 'consent': _consent};
    if (!_encodable(body)) return;
    // shortcut: identify is retried with backoff but not persisted offline; call identify again on next launch if needed.
    unawaited(_chain(() => _api.send('/ingest/v1/identify', body)));
  }

  /// Log out: forgets the profile and starts a new anonymous id. Events already queued keep the id they had.
  Future<void> reset() async {
    _profile = {};
    _aid = null;
    await _prefs.remove(_kProfile);
    await _prefs.remove(_kAid);
  }

  /// Tracks an event. [value] is in minor currency units (cents).
  void track(String name, {Map<String, Object?> properties = const {}, int? value, String? currency, String? dedupeKey}) {
    _enqueue(name, properties, value: value, currency: currency, dedupeKey: dedupeKey);
    _emit(InAppTrigger.event(name, properties));
  }

  /// A screen view: sent as a page view with the screen name, and offered to in-app messages with a screen trigger.
  void screen(String name, {Map<String, Object?> properties = const {}}) {
    _enqueue('page_view', {'screen': name, ...properties});
    _emit(InAppTrigger.screenView(name));
  }

  void _emit(InAppTrigger t) {
    if (!_triggers.isClosed) _triggers.add(t);
  }

  static const _consent = {'analytics': true, 'marketing': true};

  static bool _encodable(Object body) {
    try {
      jsonEncode(body);
      return true;
    } catch (e) {
      debugPrint('[hermetica] dropped, not JSON-encodable: $e');
      return false;
    }
  }

  /// Queues an event without offering it to in-app messages (push opens, geofences).
  void _enqueue(String name, Map<String, Object?> properties, {int? value, String? currency, String? dedupeKey}) {
    final aid = anonymousId;
    if (aid == null) return; // opted out: nothing is stored or sent
    final ev = <String, Object?>{
      'name': name,
      'properties': {...properties, 'hm_sdk': 'flutter-$sdkVersion'},
      'dedupeKey': dedupeKey ?? newUuid(),
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      'anonymousId': aid,
      if (value != null) 'value': value,
      if (currency != null) 'currency': currency,
    };
    if (!_encodable(ev)) return; // one bad event must not block the queue
    _queue.add(ev);
    if (_queue.length > maxQueue) _queue.removeRange(0, _queue.length - maxQueue); // drop oldest
    _save();
    if (_queue.length >= maxBatchSize) {
      unawaited(flush());
    } else {
      _timer ??= Timer(flushInterval, () => unawaited(flush()));
    }
  }

  /// Sends queued events now. Events that could not be sent stay queued (on disk too) and are retried later.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _chain(_drain);
  }

  Future<void> _drain() async {
    while (!_optedOut && _queue.isNotEmpty) {
      final batch = _queue.take(maxBatchSize).toList();
      if (!await _api.send('/ingest/v1/batch', {'events': batch, 'consent': _consent})) {
        _timer ??= Timer(_retryAfter, () => unawaited(flush()));
        return;
      }
      _queue.removeWhere(batch.contains); // by identity: the queue may have changed while sending
      _save();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(flush());
  }

  /// Stops timers and listeners. [initialize] calls it on the previous client.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    unawaited(_triggers.close());
    if (_ownsHttp) _api.client.close();
    if (identical(_instance, this)) _instance = null;
  }

  // ---- push ----

  Map<String, Object?> _pushBody(String type, String token, PushOptions o) => pushTokenBody(
      type: type, token: token, platform: o.platform ?? platform, options: o, device: device, sdkVersion: 'flutter-$sdkVersion', profile: _keys());

  /// Registers the device token (from firebase_messaging or APNs) with this profile. False when the server refused it.
  Future<bool> registerPushToken(String token, PushOptions options) async => _ok(await _api.post('/client/push-tokens', _pushBody('push-token', token, options)));

  /// The token stops receiving pushes (for example on logout).
  Future<bool> unregisterPushToken(String token, PushOptions options) async =>
      _ok(await _api.post('/client/push-token-unregister', _pushBody('push-token-unregister', token, options)));

  static bool _ok(http.Response? r) => r != null && r.statusCode >= 200 && r.statusCode < 300;

  /// Call when the user taps a notification, with its data map (`RemoteMessage.data`, APNs `userInfo`, ...). Tracks
  /// `$opened_push` for Hermetica messages, passes the deep link to [onDeepLink] and returns it (or null).
  String? handlePushOpened(Object? payload) {
    final d = pushData(payload);
    final messageId = nonEmpty(d['hermetica_message_id']);
    if (messageId != null) _enqueue(r'$opened_push', {'hermetica_message_id': messageId});
    final link = pushLink(d);
    if (link != null) onDeepLink?.call(link);
    return link;
  }

  // ---- in-app ----

  /// The messages that fit this moment, best first. The server applies targeting and frequency caps. Empty on any
  /// failure: a missing in-app message must never break the app.
  Future<List<InAppMessage>> fetchInAppMessages(InAppTrigger trigger) async {
    final who = _keys();
    if (who.isEmpty) return const [];
    String? props;
    if (trigger.type == 'event' && trigger.properties.isNotEmpty) props = _encodable(trigger.properties) ? jsonEncode(trigger.properties) : null;
    final body = jsonBody(await _api.get('/client/in-app-messages', {
      'platform': platform,
      'trigger': trigger.type,
      'session_id': sessionId,
      'name': trigger.name,
      'properties': props,
      ...who,
    }));
    final items = body?['items'];
    return items is List ? items.map(InAppMessage.fromJson).toList() : const [];
  }

  /// Reports `impression`, `click` (with the button label) or `dismiss`. Skipped while tracking is opted out.
  Future<void> reportInAppEvent(InAppMessage message, String type, {String? button}) async {
    if (_optedOut) return;
    final a = _keys();
    await _api.post('/client/in-app-events', {
      'events': [
        {'messageId': message.id, 'variant': message.variant, 'type': type, 'platform': platform, 'sessionId': sessionId, if (button != null) 'button': button},
      ],
      'profile': {
        for (final (wire, key) in [('external_id', 'externalId'), ('email', 'email'), ('phone_number', 'phoneNumber'), ('anonymous_id', 'anonymousId')])
          if (a[wire] != null) key: a[wire],
      },
    });
  }

  // ---- geofences ----

  /// The geofences to register with your geofencing plugin. Empty when the request fails.
  Future<List<Geofence>> getGeofences() async {
    final data = jsonBody(await _api.get('/client/geofences'))?['data'];
    return data is List ? data.map(Geofence.fromJson).toList() : const [];
  }

  /// Report a transition from your geofencing plugin; event-triggered journeys fire on `$geofence_enter` / `_exit` / `_dwell`.
  void reportGeofenceEvent(GeofenceTransition transition, String geofenceId) => _enqueue('\$geofence_${transition.name}', {'geofence_id': geofenceId});
}
