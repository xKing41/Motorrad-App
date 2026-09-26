package com.example.schraeglage

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Helm-Headset (Sena, Cardo, Interphone ... oder jedes andere
 * Bluetooth-Headset):
 *  - erkennen, welches verbunden ist, und den Akkustand lesen,
 *  - Sprachnachrichten ueber das Headset-Mikrofon aufnehmen
 *    (Bluetooth-Sprechverbindung wie beim Telefonieren),
 *  - Sprachnachrichten der Gruppe abspielen (Musik wird leiser),
 *  - auf Wunsch die Tasten am Headset fuer die App nutzen.
 */
class HeadsetBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "schraeglage/headset")
    private val audio = activity.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var player: MediaPlayer? = null
    private var focus: AudioFocusRequest? = null
    private var session: MediaSession? = null
    private var pendingPermission: MethodChannel.Result? = null

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = changed()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = changed()
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "requestPermissions" -> requestPermissions(result)
                "startRecording" -> startRecording(call.argument<String>("path")!!, result)
                "stopRecording" -> result.success(stopRecording())
                "play" -> play(call.argument<String>("path")!!, result)
                "setButtons" -> {
                    setButtons(call.argument<Boolean>("on") == true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        audio?.registerAudioDeviceCallback(deviceCallback, main)
    }

    fun dispose() {
        audio?.unregisterAudioDeviceCallback(deviceCallback)
        stopRecording()
        player?.release()
        session?.release()
    }

    private fun changed() {
        main.post { channel.invokeMethod("changed", status()) }
    }

    // ---------------------------------------------------------------
    //  Erkennen
    // ---------------------------------------------------------------

    private fun btOutputs(): List<AudioDeviceInfo> {
        val a = audio ?: return emptyList()
        return a.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                (Build.VERSION.SDK_INT >= 31 && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
        }
    }

    private fun hasBtPermission(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    /** Akkustand ueber die (nicht offizielle) Bluetooth-Schnittstelle. */
    private fun batteryOf(name: String): Int {
        if (!hasBtPermission()) return -1
        return try {
            val adapter: BluetoothAdapter? =
                activity.getSystemService(BluetoothManager::class.java)?.adapter
            val dev: BluetoothDevice = adapter?.bondedDevices?.firstOrNull { it.name == name }
                ?: return -1
            val m = dev.javaClass.getMethod("getBatteryLevel")
            (m.invoke(dev) as? Int) ?: -1
        } catch (e: Exception) {
            -1
        }
    }

    private fun status(): Map<String, Any?> {
        val outs = btOutputs()
        val d = outs.firstOrNull()
        val name = d?.productName?.toString() ?: ""
        return mapOf(
            "connected" to (d != null),
            "name" to name,
            "sco" to outs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO },
            "battery" to (if (d != null) batteryOf(name) else -1),
            "btPermission" to hasBtPermission(),
            "micPermission" to (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED),
        )
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val need = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 31) need.add(Manifest.permission.BLUETOOTH_CONNECT)
        val missing = need.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(missing.toTypedArray(), REQUEST_AUDIO)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_AUDIO) return false
        pendingPermission?.success(grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        pendingPermission = null
        changed()
        return true
    }

    // ---------------------------------------------------------------
    //  Aufnehmen ueber das Headset-Mikrofon
    // ---------------------------------------------------------------

    private fun useHeadsetMic(on: Boolean) {
        val a = audio ?: return
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                if (on) {
                    val sco = a.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                    }
                    if (sco != null) a.setCommunicationDevice(sco)
                } else {
                    a.clearCommunicationDevice()
                }
            } else {
                @Suppress("DEPRECATION")
                if (on) {
                    a.mode = AudioManager.MODE_IN_COMMUNICATION
                    a.startBluetoothSco()
                    a.isBluetoothScoOn = true
                } else {
                    a.stopBluetoothSco()
                    a.isBluetoothScoOn = false
                    a.mode = AudioManager.MODE_NORMAL
                }
            }
        } catch (e: Exception) {
            // Kein Headset-Mikrofon: dann das des Handys.
        }
    }

    private fun startRecording(path: String, result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(false)
            return
        }
        stopRecording()
        val viaHeadset = btOutputs().isNotEmpty()
        if (viaHeadset) useHeadsetMic(true)
        // Die Bluetooth-Sprechverbindung braucht einen Moment.
        main.postDelayed({
            try {
                val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(activity)
                else @Suppress("DEPRECATION") MediaRecorder()
                // VOICE_COMMUNICATION: mit Rausch- und Echounterdrueckung.
                r.setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                r.setAudioChannels(1)
                r.setAudioSamplingRate(16000)
                r.setAudioEncodingBitRate(24000)
                r.setMaxDuration(20000)
                r.setOutputFile(path)
                r.prepare()
                r.start()
                recorder = r
                result.success(true)
            } catch (e: Exception) {
                useHeadsetMic(false)
                result.success(false)
            }
        }, if (viaHeadset) 500L else 0L)
    }

    private fun stopRecording(): Boolean {
        val r = recorder ?: return false
        recorder = null
        val ok = try {
            r.stop()
            true
        } catch (e: Exception) {
            false // zu kurz
        }
        r.release()
        useHeadsetMic(false)
        return ok
    }

    // ---------------------------------------------------------------
    //  Abspielen (Musik wird leiser)
    // ---------------------------------------------------------------

    private fun play(path: String, result: MethodChannel.Result) {
        val a = audio
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        try {
            player?.release()
            if (a != null) {
                val f = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(attrs)
                    .build()
                a.requestAudioFocus(f)
                focus = f
            }
            val p = MediaPlayer()
            p.setAudioAttributes(attrs)
            p.setDataSource(path)
            p.setOnCompletionListener {
                it.release()
                player = null
                focus?.let { f -> a?.abandonAudioFocusRequest(f) }
                result.success(true)
            }
            p.setOnErrorListener { mp, _, _ ->
                mp.release()
                player = null
                focus?.let { f -> a?.abandonAudioFocusRequest(f) }
                result.success(false)
                true
            }
            p.prepare()
            p.start()
            player = p
        } catch (e: Exception) {
            focus?.let { f -> a?.abandonAudioFocusRequest(f) }
            result.success(false)
        }
    }

    // ---------------------------------------------------------------
    //  Headset-Tasten
    // ---------------------------------------------------------------

    private fun setButtons(on: Boolean) {
        if (!on) {
            session?.release()
            session = null
            return
        }
        if (session != null) return
        val s = MediaSession(activity, "schraeglage")
        s.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(intent: Intent): Boolean {
                val ev: KeyEvent? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                }
                if (ev == null || ev.action != KeyEvent.ACTION_DOWN) return true
                val name = when (ev.keyCode) {
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY,
                    KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK -> "playpause"
                    KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
                    else -> return false
                }
                main.post { channel.invokeMethod("button", name) }
                return true
            }
        })
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS
                )
                .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                .build()
        )
        s.isActive = true
        session = s
        // Android gibt die Tasten der App, die zuletzt Ton abgespielt hat -
        // ein Augenblick Stille macht die App dazu.
        playSilence()
    }

    private fun playSilence() {
        try {
            val rate = 16000
            val samples = ShortArray(rate / 10)
            val t = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(samples.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            t.write(samples, 0, samples.size)
            t.play()
            main.postDelayed({ t.release() }, 500)
        } catch (e: Exception) {
            // egal
        }
    }

    companion object {
        const val REQUEST_AUDIO = 4713
    }
}
