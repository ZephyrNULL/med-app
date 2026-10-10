package com.carecube.care_cube

import android.content.ContentUris
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "care_cube/ringtones"
    }

    private var loopPlayer: MediaPlayer? = null
    private var previewPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listTones" -> result.success(listTones())
                    "defaultAlarmUri" -> result.success(
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)?.toString()
                    )
                    "play" -> {
                        result.success(playOnce(Uri.parse(call.argument<String>("uri"))));
                    }
                    "playLoop" -> {
                        result.success(playLoop(Uri.parse(call.argument<String>("uri"))))
                    }
                    "stopPreview" -> {
                        stopPreview()
                        result.success(true)
                    }
                    "stop" -> {
                        stopPlayback()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun listTones(): List<Map<String, String>> {
        val tones = mutableListOf<Map<String, String>>()

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE
        )
        val selection = "${MediaStore.Audio.Media.IS_ALARM}=1 OR " +
                "${MediaStore.Audio.Media.IS_RINGTONE}=1"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} COLLATE LOCALIZED ASC"

        try {
            val cursor = contentResolver.query(
                MediaStore.Audio.Media.INTERNAL_CONTENT_URI,
                projection, selection, null, sortOrder
            )
            cursor?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                while (c.moveToNext()) {
                    val id = c.getLong(idCol)
                    val title = c.getString(titleCol) ?: "Ringtone"
                    val uri = ContentUris.withAppendedId(
                        MediaStore.Audio.Media.INTERNAL_CONTENT_URI, id)
                    tones.add(mapOf("uri" to uri.toString(), "name" to title))
                }
            }
        } catch (e: Exception) {
            // Query can fail on some OEMs; fall back to the defaults below.
        }

        // Always offer the system defaults so the list is never empty.
        val defaults = linkedMapOf(
            RingtoneManager.TYPE_ALARM to "Default alarm",
            RingtoneManager.TYPE_RINGTONE to "Default ringtone",
            RingtoneManager.TYPE_NOTIFICATION to "Default notification"
        )
        for ((type, label) in defaults) {
            val uri = RingtoneManager.getDefaultUri(type) ?: continue
            tones.add(0, mapOf("uri" to uri.toString(), "name" to label))
        }
        return tones
    }

    private fun audioAttrs(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

    private fun playOnce(uri: Uri): Boolean {
        stopPreview()
        return try {
            val player = MediaPlayer()
            player.setAudioAttributes(audioAttrs())
            player.setDataSource(this, uri)
            player.setOnCompletionListener { finished ->
                finished.release()
                if (previewPlayer === finished) previewPlayer = null
            }
            player.prepare()
            player.start()
            previewPlayer = player
            true
        } catch (e: Exception) {
            // Deleted file, denied URI, unreadable stream: report failure so
            // the Dart side can fall back to a bundled tone.
            false
        }
    }

    private fun playLoop(uri: Uri): Boolean {
        stopPlayback()
        return try {
            val player = MediaPlayer()
            player.setAudioAttributes(audioAttrs())
            player.setDataSource(this, uri)
            player.isLooping = true
            player.prepare()
            player.start()
            loopPlayer = player
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopPreview() {
        previewPlayer?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        previewPlayer = null
    }

    private fun stopPlayback() {
        loopPlayer?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        loopPlayer = null
    }
}