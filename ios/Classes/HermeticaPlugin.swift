import Flutter
import UIKit
import UserNotifications

/// `hermetica/push` getPushToken: the APNs token plus what the OS allows, in the server's push-token wire values.
public class HermeticaPlugin: NSObject, FlutterPlugin {
    private var token: String?
    private var waiting: [FlutterResult] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "hermetica/push", binaryMessenger: registrar.messenger())
        let plugin = HermeticaPlugin()
        registrar.addMethodCallDelegate(plugin, channel: channel)
        registrar.addApplicationDelegate(plugin) // receives the APNs registration callbacks
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "getPushToken" else { return result(FlutterMethodNotImplemented) }
        let ask = ((call.arguments as? [String: Any])?["requestPermission"] as? Bool) ?? false
        let center = UNUserNotificationCenter.current()
        let register = {
            DispatchQueue.main.async {
                if let t = self.token { return self.reply(t, result) }
                self.waiting.append(result)
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        if ask {
            center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in register() }
        } else {
            register()
        }
    }

    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let t = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = t
        let pending = waiting
        waiting = []
        for r in pending { reply(t, r) }
    }

    public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let pending = waiting
        waiting = []
        for r in pending { r(nil) }
    }

    private func reply(_ token: String, _ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status: String
            switch s.authorizationStatus {
            case .authorized, .ephemeral: status = "AUTHORIZED"
            case .denied: status = "DENIED"
            case .provisional: status = "PROVISIONAL"
            case .notDetermined: status = "NOT_DETERMINED"
            @unknown default: status = "UNAUTHORIZED"
            }
            DispatchQueue.main.async {
                let background: String
                switch UIApplication.shared.backgroundRefreshStatus {
                case .denied: background = "DENIED"
                case .restricted: background = "RESTRICTED"
                default: background = "AVAILABLE"
                }
                #if DEBUG
                let environment = "debug"
                #else
                let environment = "release"
                #endif
                result(["token": token, "vendor": "apns", "environment": environment, "enablementStatus": status, "background": background])
            }
        }
    }
}
