package com.example.schraeglage

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

/**
 * Ansagen "wie ein Anruf" ueber die Bluetooth-Freisprechverbindung (HFP).
 *
 * Viele Autoradios spielen Bluetooth-Medienton nur, wenn die Quelle
 * "Bluetooth-Audio" gewaehlt ist - bei Radio/DAB hoert man von der App
 * nichts. Anrufe unterbrechen dagegen jede Quelle. Manche Helm-Headsets
 * lassen waehrend Intercom ebenfalls nur die Sprechverbindung durch.
 * Deshalb wird die Ansage hier als Sprachverbindung ausgegeben: kurz die
 * Freisprechverbindung oeffnen, sprechen, wieder schliessen.
 */
class CallVoice(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "schraeglage/callvoice")
    private val main = Handler(Looper.getMainLooper())
    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager?
    private var tts: TextToSpeech? = null
    private var ready = false
    private val waiting = ArrayList<() -> Unit>()
    private var pending = 0
    private var focus: AudioFocusRequest? = null
    private var lastError: String? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    val rate = (call.argument<Double>("rate") ?: 0.5).toFloat()
                    val voice = call.argument<String>("voice")
                    whenReady { speak(text, rate, voice) }
                    result.success(true)
                }
                "stop" -> {
                    tts?.stop()
                    pending = 0
                    release()
                    result.success(true)
                }
                "lastError" -> result.success(lastError)
                else -> result.notImplemented()
            }
        }
    }

    private fun whenReady(f: () -> Unit) {
        if (ready) {
            f()
            return
        }
        waiting.add(f)
        if (tts != null) return
        tts = TextToSpeech(activity) { status ->
            main.post {
                if (status == TextToSpeech.SUCCESS) {
                    ready = true
                    tts?.setLanguage(Locale.GERMANY)
                    tts?.setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(id: String?) {}
                        override fun onDone(id: String?) {
                            main.post { done() }
                        }
                        @Suppress("OVERRIDE_DEPRECATION")
                        override fun onError(id: String?) {
                            lastError = "Fehler bei der Ansage"
                            main.post { done() }
                        }
                        override fun onError(id: String?, code: Int) {
                            lastError = "Fehler bei der Ansage ($code)"
                            main.post { done() }
                        }
                    })
                    val w = ArrayList(waiting)
                    waiting.clear()
                    w.forEach { it() }
                } else {
                    lastError = "Sprachausgabe nicht verfuegbar ($status)"
                    tts = null
                    waiting.clear()
                }
            }
        }
    }

    private fun speak(text: String, rate: Float, voiceName: String?) {
        val t = tts ?: return
        if (voiceName != null) {
            t.voices?.firstOrNull { it.name == voiceName }?.let { t.setVoice(it) }
        }
        t.setSpeechRate(rate * 2f) // flutter_tts: 0,5 = normal; Android: 1,0
        val first = pending == 0
        pending++
        if (first) {
            grab()
            // Die Freisprechverbindung braucht einen Moment, sonst fehlt
            // der Anfang der Ansage.
            main.postDelayed({ say(t, text) }, 900)
        } else {
            say(t, text)
        }
    }

    private fun say(t: TextToSpeech, text: String) {
        val params = Bundle()
        params.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1f)
        val r = t.speak(text, TextToSpeech.QUEUE_ADD, params, UUID.randomUUID().toString())
        if (r != TextToSpeech.SUCCESS) {
            lastError = "Ansage abgelehnt ($r)"
            done()
        }
    }

    private fun done() {
        pending = maxOf(0, pending - 1)
        if (pending == 0) {
            // Kurz nachlaufen lassen, falls gleich die naechste kommt.
            main.postDelayed({ if (pending == 0) release() }, 600)
        }
    }

    private fun grab() {
        val a = audio ?: return
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                val f = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    ).build()
                a.requestAudioFocus(f)
                focus = f
            }
            if (Build.VERSION.SDK_INT >= 31) {
                val sco = a.availableCommunicationDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                }
                if (sco != null) a.setCommunicationDevice(sco)
                else lastError = "Keine Bluetooth-Freisprechverbindung - Ansage ueber das Handy"
            } else {
                @Suppress("DEPRECATION")
                run {
                    a.mode = AudioManager.MODE_IN_COMMUNICATION
                    a.startBluetoothSco()
                    a.isBluetoothScoOn = true
                }
            }
        } catch (e: Exception) {
            lastError = "Freisprechverbindung: ${e.message}"
        }
    }

    private fun release() {
        val a = audio ?: return
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                a.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                run {
                    a.stopBluetoothSco()
                    a.isBluetoothScoOn = false
                    a.mode = AudioManager.MODE_NORMAL
                }
            }
            if (Build.VERSION.SDK_INT >= 26) focus?.let { a.abandonAudioFocusRequest(it) }
            focus = null
        } catch (e: Exception) {
            // egal
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        release()
        tts?.shutdown()
        tts = null
    }
}
