package com.example.qingyue;

import android.content.Context;
import android.content.res.AssetManager;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import com.k2fsa.sherpa.onnx.GeneratedAudio;
import com.k2fsa.sherpa.onnx.OfflineTts;
import com.k2fsa.sherpa.onnx.OfflineTtsConfig;
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig;
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig;

import java.io.IOException;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

import kotlin.jvm.functions.Function1;

final class OfflineNarrator implements AutoCloseable {
    private static final String TAG = "QingyueOfflineTts";
    private static final String MODEL_DIRECTORY = "tts/kokoro-int8-multi-lang-v1_1";
    private static final String[] MODEL_FILES = {
            "model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt",
            "lexicon-zh.txt", "phone-zh.fst", "date-zh.fst", "number-zh.fst"
    };

    enum Voice {
        FIRST("qingyue:offline-zh", "清阅普通话男声1", 58),
        SECOND("qingyue:offline-zh-2", "清阅普通话男声2", 95),
        THIRD("qingyue:offline-zh-3", "清阅普通话女声", 3);

        final String id;
        final String name;
        final int speakerId;

        Voice(String id, String name, int speakerId) {
            this.id = id;
            this.name = name;
            this.speakerId = speakerId;
        }

        static Voice select(String id) {
            if (id == null) return FIRST;
            for (Voice voice : values()) {
                if (voice.id.equals(id)) return voice;
            }
            return null;
        }
    }

    private final AssetManager assets;
    private final boolean available;
    private final String failureMessage;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();

    private volatile long generation;
    // The synthesizer belongs exclusively to the worker. The playing track belongs to main.
    private OfflineTts tts;
    private AudioTrack playing;

    // Sherpa looks up invoke(float[]) directly; a Java lambda has only the erased signature.
    private final class SynthesisCancellation implements Function1<float[], Integer> {
        private final long turn;

        SynthesisCancellation(long turn) {
            this.turn = turn;
        }

        @Override
        public Integer invoke(float[] samples) {
            return turn == generation ? 1 : 0;
        }
    }

    OfflineNarrator(Context context) {
        assets = context.getAssets();
        failureMessage = context.getString(R.string.tts_offline_failed);
        available = modelAssetsAvailable(assets);
    }

    boolean isAvailable() {
        return available;
    }

    private static boolean modelAssetsAvailable(AssetManager assets) {
        try {
            String[] files = assets.list(MODEL_DIRECTORY);
            return files != null && Arrays.asList(files).containsAll(Arrays.asList(MODEL_FILES));
        } catch (IOException missingAssets) {
            return false;
        }
    }

    private OfflineTts synthesizer() {
        if (tts == null) {
            if (!isAvailable()) throw new IllegalStateException("Missing narrator model");
            OfflineTtsKokoroModelConfig kokoro = new OfflineTtsKokoroModelConfig();
            kokoro.setModel(modelPath("model.int8.onnx"));
            kokoro.setVoices(modelPath("voices.bin"));
            kokoro.setTokens(modelPath("tokens.txt"));
            kokoro.setLexicon(modelPath("lexicon-us-en.txt") + ","
                    + modelPath("lexicon-zh.txt"));

            OfflineTtsModelConfig model = new OfflineTtsModelConfig();
            model.setKokoro(kokoro);
            model.setNumThreads(Math.max(1, Math.min(4, Runtime.getRuntime().availableProcessors())));

            OfflineTtsConfig config = new OfflineTtsConfig();
            config.setModel(model);
            config.setRuleFsts(modelPath("phone-zh.fst") + ","
                    + modelPath("date-zh.fst") + ","
                    + modelPath("number-zh.fst"));
            OfflineTts candidate = new OfflineTts(assets, config);
            if (candidate.sampleRate() <= 0) {
                candidate.release();
                throw new IllegalStateException("Invalid synthesis sample rate");
            }
            tts = candidate;
        }
        return tts;
    }

    private static String modelPath(String name) {
        return MODEL_DIRECTORY + "/" + name;
    }

    void speak(String text, float speed, Voice voice, Consumer<String> completion) {
        stop();
        long turn = generation;
        worker.execute(() -> {
            if (turn != generation) return;
            AudioTrack track = null;
            try {
                OfflineTts model = synthesizer();
                if (voice.speakerId >= model.numSpeakers()) {
                    throw new IllegalStateException("Selected speaker is missing from the model");
                }
                GeneratedAudio audio = model.generateWithCallback(
                        text, voice.speakerId, speed, new SynthesisCancellation(turn));
                if (turn != generation) return;
                float[] samples = audio.getSamples();
                int sampleRate = audio.getSampleRate();
                if (samples.length == 0 || sampleRate <= 0) {
                    if (text.codePoints().noneMatch(Character::isLetterOrDigit)) {
                        report(turn, completion, null);
                        return;
                    }
                    throw new IllegalStateException("No speech samples generated");
                }
                short[] pcm = new short[samples.length];
                for (int i = 0; i < samples.length; i++) {
                    pcm[i] = (short) Math.round(Math.max(-1f, Math.min(1f, samples[i])) * 32767f);
                }
                if (turn != generation) return;
                track = new AudioTrack.Builder()
                        .setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build())
                        .setAudioFormat(new AudioFormat.Builder()
                                .setSampleRate(sampleRate)
                                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .build())
                        .setTransferMode(AudioTrack.MODE_STATIC)
                        .setBufferSizeInBytes(pcm.length * Short.BYTES)
                        .build();
                if (track.write(pcm, 0, pcm.length, AudioTrack.WRITE_BLOCKING) != pcm.length) {
                    throw new IllegalStateException("Incomplete speech audio buffer");
                }
                AudioTrack prepared = track;
                int frames = pcm.length;
                main.post(() -> play(turn, prepared, frames, sampleRate, completion));
                track = null;
            } catch (RuntimeException | LinkageError failure) {
                Log.w(TAG, "Could not synthesize or buffer audio", failure);
                report(turn, completion, failureMessage);
            } finally {
                if (track != null) track.release();
            }
        });
    }

    private void play(long turn, AudioTrack track, int frames, int sampleRate,
                      Consumer<String> completion) {
        if (turn != generation) {
            track.release();
            return;
        }
        playing = track;
        try {
            track.setPlaybackPositionUpdateListener(new AudioTrack.OnPlaybackPositionUpdateListener() {
                @Override
                public void onMarkerReached(AudioTrack ended) {
                    finish(turn, ended, completion, null);
                }

                @Override
                public void onPeriodicNotification(AudioTrack ignored) {}
            }, main);
            track.setNotificationMarkerPosition(frames);
            track.play();
            long deadline = SystemClock.uptimeMillis() + frames * 1000L / sampleRate + 5000;
            // Some devices miss a marker at the exact last frame. Check the actual head as a fallback.
            main.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (turn != generation || playing != track) return;
                    if (track.getPlaybackHeadPosition() >= frames) {
                        finish(turn, track, completion, null);
                    } else if (SystemClock.uptimeMillis() >= deadline) {
                        finish(turn, track, completion, failureMessage);
                    } else {
                        main.postDelayed(this, 250);
                    }
                }
            }, 250);
        } catch (RuntimeException failure) {
            Log.w(TAG, "Could not play speech audio", failure);
            finish(turn, track, completion, failureMessage);
        }
    }

    private void report(long turn, Consumer<String> completion, String message) {
        main.post(() -> {
            if (turn == generation) completion.accept(message);
        });
    }

    private void finish(long turn, AudioTrack track, Consumer<String> completion, String message) {
        if (turn != generation || playing != track) return;
        stopTrack();
        completion.accept(message);
    }

    private void stopTrack() {
        AudioTrack track = playing;
        playing = null;
        if (track == null) return;
        try {
            track.stop();
        } catch (IllegalStateException ignored) {
            // Initialization failure can leave a track that still needs to be released.
        } finally {
            track.release();
        }
    }

    void stop() {
        generation++;
        stopTrack();
    }

    @Override
    public void close() {
        stop();
        worker.execute(() -> {
            if (tts != null) tts.release();
        });
        worker.shutdown();
    }
}
