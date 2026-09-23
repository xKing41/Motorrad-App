package com.example.schraeglage

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }

    private fun hasSmsPermission(): Boolean =
        checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_SMS) {
            val ok = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermission?.success(ok)
            pendingPermission = null
        }
    }

    companion object {
        private const val REQUEST_SMS = 4711
    }
}
