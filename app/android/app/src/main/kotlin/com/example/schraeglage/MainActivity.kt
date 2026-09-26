package com.example.schraeglage

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Ersetzt die MainActivity aus "flutter create".
 *
 * Einzige Ergaenzung: Die Notfall-SMS kann nach dem Sturz-Countdown
 * direkt verschickt werden - ohne dass jemand in der SMS-App auf
 * "Senden" tippen muss. Wer nach einem Sturz bewusstlos ist, kann das
 * naemlich nicht.
 */
class MainActivity : FlutterActivity() {
    private var pendingPermission: MethodChannel.Result? = null
    private var headset: HeadsetBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Helm-Headset: erkennen, Akku, Sprachnachrichten, Tasten.
        headset?.dispose()
        headset = HeadsetBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "schraeglage/sms")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasSmsPermission())
                    "requestPermission" -> {
                        if (hasSmsPermission()) {
                            result.success(true)
                        } else {
                            pendingPermission?.success(false)
                            pendingPermission = result
                            requestPermissions(arrayOf(Manifest.permission.SEND_SMS), REQUEST_SMS)
                        }
                    }
                    "send" -> {
                        val phone = call.argument<String>("phone")
                        val text = call.argument<String>("text")
                        if (phone.isNullOrBlank() || text.isNullOrBlank() || !hasSmsPermission()) {
                            result.success(false)
                        } else {
                            try {
                                val sms: SmsManager? = if (Build.VERSION.SDK_INT >= 31) {
                                    getSystemService(SmsManager::class.java)
                                } else {
                                    @Suppress("DEPRECATION")
                                    SmsManager.getDefault()
                                }
                                if (sms == null) {
                                    result.success(false)
                                } else {
                                    val parts = sms.divideMessage(text)
                                    sms.sendMultipartTextMessage(phone, null, parts, null, null)
                                    result.success(true)
                                }
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Hintergrundbetrieb: Benachrichtigung (fuer die Anzeige "Fahrt
        // laeuft") und Akku-Optimierung von Android.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "schraeglage/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT < 33 ||
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQUEST_NOTIFY
                            )
                            result.success(false)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(PowerManager::class.java)
                        result.success(pm?.isIgnoringBatteryOptimizations(packageName) ?: true)
                    }
                    "openBatterySettings" -> {
                        try {
                            // Direkt die Abfrage fuer diese App. Klappt das nicht
                            // (manche Hersteller sperren es), die Liste aller Apps.
                            val i = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasSmsPermission(): Boolean =
        checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (headset?.onPermissionResult(requestCode, grantResults) == true) return
        if (requestCode == REQUEST_SMS) {
            val ok = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermission?.success(ok)
            pendingPermission = null
        }
    }

    override fun onDestroy() {
        headset?.dispose()
        headset = null
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_SMS = 4711
        private const val REQUEST_NOTIFY = 4712
    }
}
