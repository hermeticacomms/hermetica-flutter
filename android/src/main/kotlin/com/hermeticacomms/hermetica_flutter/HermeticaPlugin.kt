package com.hermeticacomms.hermetica_flutter

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** `hermetica/push` getPushToken: the FCM token plus what the OS allows, in the server's push-token wire values. */
class HermeticaPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var waiting: (() -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "hermetica/push")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getPushToken") return result.notImplemented()
        val ask = call.argument<Boolean>("requestPermission") == true
        val act: Activity? = activity?.activity
        if (ask && Build.VERSION.SDK_INT >= 33 && !granted() && act != null && waiting == null) {
            waiting = { readToken(result) }
            act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST)
        } else {
            readToken(result)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST) return false
        waiting?.invoke()
        waiting = null
        return true
    }

    private fun readToken(result: MethodChannel.Result) {
        val fcm = try { Class.forName("com.google.firebase.messaging.FirebaseMessaging"); true } catch (_: ClassNotFoundException) { false }
        if (!fcm) return result.success(null)
        try {
            com.google.firebase.messaging.FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                val token = if (task.isSuccessful) task.result else null
                result.success(token?.let { reply(it) })
            }
        } catch (_: IllegalStateException) {
            result.success(null) // Firebase is not initialized in this app
        }
    }

    private fun granted() = Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun reply(token: String): Map<String, String> {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val enabled = granted() && (Build.VERSION.SDK_INT < 24 || nm.areNotificationsEnabled())
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val restricted = Build.VERSION.SDK_INT >= 28 && am.isBackgroundRestricted
        val debug = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        return mapOf(
            "token" to token,
            "vendor" to "fcm",
            "environment" to if (debug) "debug" else "release",
            "enablementStatus" to if (enabled) "AUTHORIZED" else "DENIED",
            "background" to if (restricted) "RESTRICTED" else "AVAILABLE",
        )
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    private companion object {
        const val REQUEST = 0x4d48 // "HM"
    }
}
