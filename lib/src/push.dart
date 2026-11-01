import 'models.dart';

/// The push-token JSON:API body (`type` is `push-token` to register, `push-token-unregister` to remove).
Map<String, Object?> pushTokenBody({
  required String type,
  required String token,
  required String platform,
  required PushOptions options,
  required DeviceMetadata device,
  required String sdkVersion,
  required Map<String, String> profile,
}) =>
    {
      'data': {
        'type': type,
        'attributes': {
          'token': token,
          'platform': platform,
          'vendor': options.vendor.name,
          'enablement_status': options.enablementStatus.wire,
          'background': options.background.wire,
          'device_metadata': {
            'device_id': profile['anonymous_id'] ?? '',
            'sdk_version': sdkVersion,
            'device_model': device.deviceModel ?? '',
            'os_name': device.osName ?? platform,
            'os_version': device.osVersion ?? '',
            'app_name': device.appName ?? '',
            'app_version': device.appVersion ?? '',
            'app_build': device.appBuild ?? '',
            'app_id': device.appId ?? '',
            'environment': options.environment.name,
          },
          'profile': {
            'data': {'type': 'profile', 'attributes': profile},
          },
        },
      },
    };

Map<String, Object?>? _bag(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : null;

/// Where push plugins put the custom data: FCM `RemoteMessage.data`, APNs `userInfo`, and nested notification/request
/// shapes. Merged outermost first, so inner layers win.
Map<String, Object?> pushData(Object? payload) {
  final p = _bag(payload);
  if (p == null) return const {};
  final layers = <Map<String, Object?>>[p];
  for (final n in [p['data'], p['userInfo'], p['notification'], p['request']].map(_bag).whereType<Map<String, Object?>>()) {
    layers.add(n);
    final inner = [n['data'], _bag(_bag(n['request'])?['content'])?['data'], _bag(n['content'])?['data']];
    layers.addAll(inner.map(_bag).whereType<Map<String, Object?>>());
  }
  return {for (final l in layers) ...l};
}

String? nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;

/// The deep link a notification carries, or null.
String? pushLink(Map<String, Object?> data) => nonEmpty(data['deep_link']) ?? nonEmpty(data['url']) ?? nonEmpty(data['hermetica_url']);
