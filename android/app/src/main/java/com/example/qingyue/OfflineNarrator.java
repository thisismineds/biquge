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
import com.k2fsa.sherpa.onnx.OfflineTtsVitsModelConfig;

import java.io.IOException;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;

import kotlin.jvm.functions.Function1;

final class OfflineNarrator implements AutoCloseable {
    private static final String TAG = "QingyueOfflineTts";

    private enum Model {
        KOKORO("tts/kokoro-int8-multi-lang-v1_1",
                "model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt",
                "lexicon-zh.txt", "phone-zh.fst", "date-zh.fst", "number-zh.fst"),
        CHAOWEN("tts/chaowen-fast",
                "model.onnx", "lexicon.txt", "tokens.txt", "phone.fst", "date.fst", "number.fst");

        final String directory;
        final String[] requiredFiles;

        Model(String directory, String... requiredFiles) {
            this.directory = directory;
            this.requiredFiles = requiredFiles;
        }

        String path(String name) {
            return directory + "/" + name;
        }
    }

    enum Voice {
        FIRST("qingyue:offline-zh", "清阅普通话男声1", Model.KOKORO, 58),
        SECOND("qingyue:offline-zh-2", "清阅普通话男声2", Model.KOKORO, 95),
        THIRD("qingyue:offline-zh-3", "清阅普通话女声", Model.KOKORO, 3),
        CHAOWEN("qingyue:offline-zh-chaowen", "超文 · 轻量普通话男声", Model.CHAOWEN, 0);

        final String id;
        final String name;
        final Model model;
        final int speakerId;

        Voice(String id, String name, Model model, int speakerId) {
            this.id = id;
            this.name = name;
            this.model = model;
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
    private final EnumSet<Model> available = EnumSet.noneOf(Model.class);
    private final String failureMessage;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ThreadPoolExecutor worker = new ThreadPoolExecutor(
            1, 1, 0, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>());

    // The synthesizer belongs exclusively to the worker. Playback slots belong to main.
    private OfflineTts tts;
    private Model loadedModel;
    private Segment current;
    private Segment prepared;
    private AudioTrack playing;

    private final class Segment implements Runnable {
        final long id;
        final String text;
        final float speed;
        final Voice voice;
        volatile boolean cancelled;
        Consumer<String> completion;
        BufferedSpeech ready;
        boolean retryOnPreparationFailure;

        Segment(long id, String text, float speed, Voice voice) {
            this.id = id;
            this.text = text;
            this.speed = speed;
            this.voice = voice;
        }

        boolean matches(long id, String text, float speed, Voice voice) {
            return this.id == id && this.speed == speed && this.voice == voice
                    && this.text.equals(text);
        }

        @Override
        public void run() {
            synthesize(this);
        }
    }

    private static final class BufferedSpeech {
        final AudioTrack track;
        final int frames;
        final int sampleRate;
        final String failure;

        BufferedSpeech(AudioTrack track, int frames, int sampleRate, String failure) {
            this.track = track;
            this.frames = frames;
            this.sampleRate = sampleRate;
            this.failure = failure;
        }

        void release() {
            if (track != null) track.release();
        }
    }

    // Sherpa looks up invoke(float[]) directly; a Java lambda has only the erased signature.
    private final class SynthesisCancellation implements Function1<float[], Integer> {
        private final Segment segment;

        SynthesisCancellation(Segment segment) {
            this.segment = segment;
        }

        @Override
        public Integer invoke(float[] samples) {
            return segment.cancelled ? 0 : 1;
        }
    }

    OfflineNarrator(Context context) {
        assets = context.getAssets();
        failureMessage = context.getString(R.string.tts_offline_failed);
        for (Model model : Model.values()) {
            if (modelAssetsAvailable(assets, model)) available.add(model);
        }
    }

    boolean isAvailable(Voice voice) {
        return available.contains(voice.model);
    }

    private static boolean modelAssetsAvailable(AssetManager assets, Model model) {
        try {
            String[] files = assets.list(model.directory);
            return files != null && Arrays.asList(files).containsAll(Arrays.asList(model.requiredFiles));
        } catch (IOException missingAssets) {
            return false;
        }
    }

    private OfflineTts synthesizer(Voice voice) {
        Model requested = voice.model;
        if (tts != null && loadedModel == requested) return tts;
        if (!isAvailable(voice)) throw new IllegalStateException("Missing narrator model");
        releaseSynthesizer();

        OfflineTtsModelConfig model = new OfflineTtsModelConfig();
        model.setNumThreads(Math.max(1, Math.min(4, Runtime.getRuntime().availableProcessors())));
        OfflineTtsConfig config = new OfflineTtsConfig();
        config.setModel(model);
        if (requested == Model.KOKORO) {
            OfflineTtsKokoroModelConfig kokoro = new OfflineTtsKokoroModelConfig();
            kokoro.setModel(requested.path("model.int8.onnx"));
            kokoro.setVoices(requested.path("voices.bin"));
            kokoro.setTokens(requested.path("tokens.txt"));
            kokoro.setLexicon(requested.path("lexicon-us-en.txt") + ","
                    + requested.path("lexicon-zh.txt"));
            model.setKokoro(kokoro);
            config.setRuleFsts(requested.path("phone-zh.fst") + ","
                    + requested.path("date-zh.fst") + ","
                    + requested.path("number-zh.fst"));
        } else {
            OfflineTtsVitsModelConfig vits = new OfflineTtsVitsModelConfig();
            vits.setModel(requested.path("model.onnx"));
            vits.setLexicon(requested.path("lexicon.txt"));
            vits.setTokens(requested.path("tokens.txt"));
            vits.setNoiseScale(0.5f);
            vits.setNoiseScaleW(0.333f);
            vits.setLengthScale(1f);
            model.setVits(vits);
            config.setRuleFsts(requested.path("phone.fst") + ","
                    + requested.path("date.fst") + ","
                    + requested.path("number.fst"));
        }
        OfflineTts candidate = new OfflineTts(assets, config);
        if (candidate.sampleRate() <= 0) {
            candidate.release();
            throw new IllegalStateException("Invalid synthesis sample rate");
        }
        tts = candidate;
        loadedModel = requested;
        return tts;
    }

    private void releaseSynthesizer() {
        OfflineTts previous = tts;
        tts = null;
        loadedModel = null;
        if (previous != null) previous.release();
    }

    void prepare(long id, String text, float speed, Voice voice) {
        if (current == null || current.id == id
                || (prepared != null && prepared.matches(id, text, speed, voice))) return;
        discard(prepared);
        prepared = new Segment(id, text, speed, voice);
        prepared.retryOnPreparationFailure = true;
        worker.execute(prepared);
    }

    void speak(long id, String text, float speed, Voice voice, Consumer<String> completion) {
        discard(current);
        stopTrack();
        Segment next = prepared;
        prepared = null;
        if (next != null && next.matches(id, text, speed, voice)) {
            if (Log.isLoggable(TAG, Log.DEBUG)
                    && (next.ready == null || next.ready.track != null)) {
                Log.d(TAG, next.ready == null ? "Reused in-flight segment" : "Reused buffered segment");
            }
            current = next;
            current.completion = completion;
            playWhenReady(next);
        } else {
            discard(next);
            current = new Segment(id, text, speed, voice);
            current.completion = completion;
            worker.execute(current);
        }
    }

    private void synthesize(Segment segment) {
        if (segment.cancelled) return;
        AudioTrack track = null;
        try {
            OfflineTts model = synthesizer(segment.voice);
            if (segment.cancelled) return;
            if (segment.voice.speakerId >= model.numSpeakers()) {
                throw new IllegalStateException("Selected speaker is missing from the model");
            }
            GeneratedAudio audio = model.generateWithCallback(segment.text, segment.voice.speakerId,
                    segment.speed, new SynthesisCancellation(segment));
            if (segment.cancelled) return;
            float[] samples = audio.getSamples();
            int sampleRate = audio.getSampleRate();
            if (samples.length == 0 || sampleRate <= 0) {
                if (segment.text.codePoints().noneMatch(Character::isLetterOrDigit)) {
                    publish(segment, new BufferedSpeech(null, 0, 0, null));
                    return;
                }
                throw new IllegalStateException("No speech samples generated");
            }
            short[] pcm = new short[samples.length];
            for (int i = 0; i < samples.length; i++) {
                pcm[i] = (short) Math.round(Math.max(-1f, Math.min(1f, samples[i])) * 32767f);
            }
            if (segment.cancelled) return;
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
            publish(segment, new BufferedSpeech(track, pcm.length, sampleRate, null));
            track = null;
        } catch (RuntimeException | LinkageError failure) {
            if (!segment.cancelled) {
                Log.w(TAG, "Could not synthesize or buffer audio", failure);
                publish(segment, new BufferedSpeech(null, 0, 0, failureMessage));
            }
        } finally {
            if (track != null) track.release();
        }
    }

    private void publish(Segment segment, BufferedSpeech audio) {
        if (!main.post(() -> {
            if (segment.cancelled || (segment != current && segment != prepared)) {
                audio.release();
                return;
            }
            segment.ready = audio;
            if (segment == current) {
                playWhenReady(segment);
            } else if (audio.track != null && Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "Buffered next narration segment");
            }
        })) audio.release();
    }

    private void playWhenReady(Segment segment) {
        BufferedSpeech audio = segment.ready;
        if (audio == null) return;
        segment.ready = null;
        if (audio.track == null) {
            if (audio.failure != null && segment.retryOnPreparationFailure) {
                segment.retryOnPreparationFailure = false;
                worker.execute(segment);
                return;
            }
            complete(segment, audio.failure);
            return;
        }
        AudioTrack track = audio.track;
        playing = track;
        try {
            track.setPlaybackPositionUpdateListener(new AudioTrack.OnPlaybackPositionUpdateListener() {
                @Override
                public void onMarkerReached(AudioTrack ended) {
                    finish(segment, ended, null);
                }

                @Override
                public void onPeriodicNotification(AudioTrack ignored) {}
            }, main);
            track.setNotificationMarkerPosition(audio.frames);
            track.play();
            long deadline = SystemClock.uptimeMillis()
                    + audio.frames * 1000L / audio.sampleRate + 5000;
            // Some devices miss a marker at the exact last frame. Check the actual head as a fallback.
            main.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (segment != current || playing != track) return;
                    if (track.getPlaybackHeadPosition() >= audio.frames) {
                        finish(segment, track, null);
                    } else if (SystemClock.uptimeMillis() >= deadline) {
                        finish(segment, track, failureMessage);
                    } else {
                        main.postDelayed(this, 250);
                    }
                }
            }, 250);
        } catch (RuntimeException failure) {
            Log.w(TAG, "Could not play speech audio", failure);
            finish(segment, track, failureMessage);
        }
    }

    private void complete(Segment segment, String message) {
        if (segment != current) return;
        current = null;
        if (message != null) {
            discard(prepared);
            prepared = null;
        }
        segment.completion.accept(message);
    }

    private void finish(Segment segment, AudioTrack track, String message) {
        if (segment != current || playing != track) return;
        stopTrack();
        complete(segment, message);
    }

    private void discard(Segment segment) {
        if (segment == null) return;
        segment.cancelled = true;
        worker.remove(segment);
        if (segment.ready != null) {
            segment.ready.release();
            segment.ready = null;
        }
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
        discard(current);
        discard(prepared);
        current = null;
        prepared = null;
        stopTrack();
    }

    @Override
    public void close() {
        stop();
        worker.execute(this::releaseSynthesizer);
        worker.shutdown();
    }
}
