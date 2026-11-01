Map<String, Object?> _map(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : const {};
String? _str(Object? v) => v is String ? v : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;

/// A button in an in-app message.
class InAppButton {
  const InAppButton({required this.label, required this.action, this.value, this.style = 'primary'});

  factory InAppButton.fromJson(Object? json) {
    final m = _map(json);
    return InAppButton(label: _str(m['label']) ?? '', action: _str(m['action']) ?? 'dismiss', value: _str(m['value']), style: _str(m['style']) ?? 'primary');
  }

  final String label;

  /// `dismiss`, `deep_link`, `url` or `event`.
  final String action;

  /// The link for `deep_link` / `url`, the event name for `event`.
  final String? value;

  /// `primary` or `secondary`.
  final String style;
}

/// One content block: `heading`, `text`, `image` or `buttons`.
class InAppBlock {
  const InAppBlock({required this.type, this.text, this.url, this.alt, this.buttons = const []});

  factory InAppBlock.fromJson(Object? json) {
    final m = _map(json);
    final buttons = m['buttons'];
    return InAppBlock(
      type: _str(m['type']) ?? 'text',
      text: _str(m['text']),
      url: _str(m['url']),
      alt: _str(m['alt']),
      buttons: buttons is List ? buttons.map(InAppButton.fromJson).toList() : const [],
    );
  }

  final String type;
  final String? text;
  final String? url;
  final String? alt;
  final List<InAppButton> buttons;
}

/// Colours are CSS hex strings (`#rgb`, `#rrggbb`, `#rrggbbaa`).
class InAppStyle {
  const InAppStyle({this.background = '#ffffff', this.textColor = '#111111', this.accentColor = '#2563eb', this.radius = 12, this.dismissible = true});

  factory InAppStyle.fromJson(Object? json) {
    final m = _map(json);
    return InAppStyle(
      background: _str(m['background']) ?? '#ffffff',
      textColor: _str(m['textColor']) ?? '#111111',
      accentColor: _str(m['accentColor']) ?? '#2563eb',
      radius: _num(m['radius']) ?? 12,
      dismissible: m['dismissible'] is bool ? m['dismissible'] as bool : true,
    );
  }

  final String background;
  final String textColor;
  final String accentColor;
  final double radius;
  final bool dismissible;
}

/// An in-app message the server picked for this moment.
class InAppMessage {
  const InAppMessage({
    required this.id,
    this.variant = 'a',
    this.layout = 'modal',
    this.queued = false,
    this.priority = 0,
    this.blocks = const [],
    this.html,
    this.style = const InAppStyle(),
  });

  factory InAppMessage.fromJson(Object? json) {
    final m = _map(json);
    final content = _map(m['content']);
    final blocks = content['blocks'];
    return InAppMessage(
      id: _str(m['id']) ?? '',
      variant: _str(m['variant']) ?? 'a',
      layout: _str(m['layout']) ?? 'modal',
      queued: m['queued'] == true,
      priority: (_num(m['priority']) ?? 0).toInt(),
      blocks: blocks is List ? blocks.map(InAppBlock.fromJson).toList() : const [],
      html: _str(content['html']),
      style: InAppStyle.fromJson(m['style']),
    );
  }

  final String id;
  final String variant;

  /// `modal`, `banner_top`, `banner_bottom`, `fullscreen` or `bottom_sheet`.
  final String layout;
  final bool queued;
  final int priority;
  final List<InAppBlock> blocks;

  /// Web only; the Flutter host renders [blocks].
  final String? html;
  final InAppStyle style;
}

/// A moment that can show an in-app message.
class InAppTrigger {
  const InAppTrigger.appOpen()
      : type = 'app_open',
        name = null,
        properties = const {};
  const InAppTrigger.screenView(String this.name)
      : type = 'screen_view',
        properties = const {};
  const InAppTrigger.event(String this.name, [this.properties = const {}]) : type = 'event';

  /// `app_open`, `screen_view` or `event`.
  final String type;
  final String? name;
  final Map<String, Object?> properties;
}

/// A geofence to register with your OS geofencing plugin (radius in metres).
class Geofence {
  const Geofence({required this.id, required this.name, required this.latitude, required this.longitude, required this.radius});

  /// One item of the JSON:API list (`{id, attributes: {...}}`).
  factory Geofence.fromJson(Object? json) {
    final m = _map(json);
    final a = _map(m['attributes']);
    return Geofence(id: _str(m['id']) ?? '', name: _str(a['name']) ?? '', latitude: _num(a['latitude']) ?? 0, longitude: _num(a['longitude']) ?? 0, radius: _num(a['radius']) ?? 0);
  }

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final double radius;
}

enum GeofenceTransition { enter, exit, dwell }

enum PushVendor { apns, fcm }

enum PushEnvironment { debug, release }

enum PushEnablement {
  authorized('AUTHORIZED'),
  denied('DENIED'),
  notDetermined('NOT_DETERMINED'),
  provisional('PROVISIONAL'),
  unauthorized('UNAUTHORIZED');

  const PushEnablement(this.wire);
  final String wire;
}

enum PushBackground {
  available('AVAILABLE'),
  denied('DENIED'),
  restricted('RESTRICTED');

  const PushBackground(this.wire);
  final String wire;
}

/// How the token was obtained and what the user allowed.
class PushOptions {
  const PushOptions({
    required this.vendor,
    this.environment = PushEnvironment.release,
    this.enablementStatus = PushEnablement.authorized,
    this.background = PushBackground.available,
    this.platform,
  });

  final PushVendor vendor;
  final PushEnvironment environment;
  final PushEnablement enablementStatus;
  final PushBackground background;

  /// `ios` or `android`; defaults to the client's platform.
  final String? platform;
}

/// Optional description of the app and handset, sent with push tokens. Fill it from device_info_plus / package_info_plus.
class DeviceMetadata {
  const DeviceMetadata({this.deviceModel, this.osName, this.osVersion, this.appName, this.appVersion, this.appBuild, this.appId});

  final String? deviceModel;
  final String? osName;
  final String? osVersion;
  final String? appName;
  final String? appVersion;
  final String? appBuild;
  final String? appId;
}
