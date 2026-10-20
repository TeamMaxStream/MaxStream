package com.maxstream.app.player

import java.io.ByteArrayInputStream
import java.io.File
import javax.sound.sampled.AudioFileFormat
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioInputStream
import javax.sound.sampled.AudioSystem
import kotlin.math.PI
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertTrue
import org.junit.Assume.assumeTrue

/**
 * Manual smoke test: MPV_SMOKE=1 plus a system libmpv. It exercises the same
 * software render path the app uses and never runs in CI.
 */
class MpvSmokeTest {

    @Test
    fun playsAudioAndVideo() {
        assumeTrue(System.getenv("MPV_SMOKE") == "1")

        val wav = generateWav()
        val controller = PlayerController(mapOf("ao" to "null", "terminal" to "yes"))
        controller.setVideoViewport(640, 360)
        try {
            controller.play(wav.absolutePath, null, null, null)
            await("audio playback") {
                controller.hasMedia() && controller.isPlaying && controller.time() > 0L
            }
            assertTrue(controller.length() > 500L, "expected audio duration, got ${controller.length()}")
            val midpoint = controller.length() / 2
            controller.setTime(midpoint)
            await("seek") { kotlin.math.abs(controller.time() - midpoint) < 1_500L }

            val video = File.createTempFile("maxstream-smoke", ".mp4")
            video.deleteOnExit()
            val ffmpeg = ProcessBuilder(
                "ffmpeg", "-y", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc=size=320x180:rate=10:duration=2",
                "-c:v", "mpeg4", video.absolutePath,
            ).start()
            val generated = ffmpeg.waitFor() == 0 && video.length() > 0
            if (generated) {
                controller.play(video.absolutePath, null, null, null)
                await("video playback") {
                    controller.hasMedia() && controller.length() > 0L
                }
                await("rendered frame") { controller.videoFrame != null }
                Thread.sleep(1_000)
                val frame = controller.videoFrame
                assertTrue(frame != null, "expected a video frame")
                assertTrue(frame.width == 640 && frame.height == 360, "unexpected frame size")
                assertTrue(frame.data.size > 0, "frame has no pixel data")
                assertTrue(controller.isPlaying, "video should still be playing")
                assertTrue(controller.time() > 300L, "video clock did not advance")
            }
            controller.stop()
            assertTrue(!controller.hasMedia())
        } finally {
            controller.release()
        }
    }

    private fun await(label: String, timeoutMs: Long = 15_000L, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(100)
        }
        throw AssertionError("Timed out waiting for $label")
    }

    private fun generateWav(): File {
        val format = AudioFormat(44_100f, 16, 1, true, false)
        val seconds = 3
        val samples = ByteArray(44_100 * seconds * 2)
        for (i in 0 until 44_100 * seconds) {
            val value = (sin(2 * PI * 440.0 * i / 44_100.0) * 12_000).toInt().toShort()
            samples[i * 2] = (value.toInt() and 0xFF).toByte()
            samples[i * 2 + 1] = ((value.toInt() shr 8) and 0xFF).toByte()
        }
        val file = File.createTempFile("maxstream-smoke", ".wav")
        file.deleteOnExit()
        AudioInputStream(ByteArrayInputStream(samples), format, samples.size.toLong() / 2).use { stream ->
            AudioSystem.write(stream, AudioFileFormat.Type.WAVE, file)
        }
        return file
    }
}
