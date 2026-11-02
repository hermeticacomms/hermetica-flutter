import 'package:flutter/services.dart';

import 'models.dart';

/// The plugin's native side (android/, ios/): FCM token on Android, APNs token on iOS, and what the OS allows.
const pushChannel = MethodChannel('hermetica/push');

/// A device token read by the native plugin, with the options it was obtained under.
class NativePushToken {
  const NativePushToken(this.token, this.options);

  /// From the plugin's reply; null when it has no token (no Firebase on Android, registration failed on iOS).
  static NativePushToken? fromMap(Object? reply) {
    if (reply is! Map) return null;
    final token = reply['token'];
    if (token is! String || token.isEmpty) return null;
    T pick<T extends Enum>(List<T> values, String Function(T) wire, Object? v, T fallback) =>
        values.firstWhere((e) => wire(e) == v, orElse: () => fallback);
    return NativePushToken(
      token,
      PushOptions(
        vendor: pick(PushVendor.values, (e) => e.name, reply['vendor'], PushVendor.fcm),
        environment: pick(PushEnvironment.values, (e) => e.name, reply['environment'], PushEnvironment.release),
        enablementStatus: pick(PushEnablement.values, (e) => e.wire, reply['enablementStatus'], PushEnablement.notDetermined),
        background: pick(PushBackground.values, (e) => e.wire, reply['background'], PushBackground.available),
      ),
    );
  }

  final String token;
  final PushOptions options;

  /// Same token under the same options: nothing to re-register.
  bool sameAs(NativePushToken? o) =>
      o != null &&
      o.token == token &&
      o.options.vendor == options.vendor &&
      o.options.environment == options.environment &&
      o.options.enablementStatus == options.enablementStatus &&
      o.options.background == options.background;
}

/// Asks the plugin for the token. [requestPermission] shows the OS prompt when the user has not decided yet. Null on
/// platforms without the plugin (web, desktop, tests) or when no token is available.
Future<NativePushToken?> readNativePushToken({required bool requestPermission}) async {
  try {
    return NativePushToken.fromMap(await pushChannel.invokeMethod<Object?>('getPushToken', {'requestPermission': requestPermission}));
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
