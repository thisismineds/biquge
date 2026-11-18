package com.example.qingyue;

import android.content.Context;
import android.content.res.AssetManager;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.PlaybackParams;
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

import ai.onnxruntime.OrtException;

import org.json.JSONException;

import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.IntConsumer;

import kotlin.jvm.functions.Function1;

final class OfflineNarrator implements AutoCloseable {
    private static final String TAG = "QingyueOfflineTts";
    private static final String COMPUTER_FAILURE =
            "电脑合成未能返回音频。请确认服务已启动、地址正确，且手机与电脑连接同一局域网。";
    private static final int PCM_BLOCK_SAMPLES = 32768;
    private static final Object CACHE_SETUP_LOCK = new Object();
    private static boolean checkedSpeechCache;

    private enum Model {
        KOKORO("tts/kokoro-int8-multi-lang-v1_1",
                "model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt",
                "lexicon-zh.txt", "phone-zh.fst", "date-zh.fst", "number-zh.fst"),
        CHAOWEN("tts/chaowen-fast",
                "model.onnx", "lexicon.txt", "tokens.txt", "phone.fst", "date.fst", "number.fst"),
        BROADCAST("tts/broadcast-moss-v1", "browser_poc_manifest.json", "tts_browser_onnx_meta.json",
                "qwen-reference-rvq.json", "tokenizer.onnx", "moss_tts_prefill.onnx",
                "moss_tts_decode_step.onnx", "moss_tts_local_fixed_sampled_frame.onnx",
                "moss_tts_global_shared_int8.data", "moss_tts_local_fixed_sampled_frame_int8.data",
                "codec_browser_onnx_meta.json", "moss_audio_tokenizer_decode_step.onnx",
                "moss_audio_tokenizer_decode_shared.data");

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
        CLEAR("qingyue:offline-zh-clear", "清朗播音 · 原创男声", Model.BROADCAST, 0),
        COMPUTER("qingyue:offline-zh-pc", "清朗播音 · 电脑合成", null, 0),
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
    private final File modelStorage;
    private final File speechCache;
    private final EnumSet<Model> available = EnumSet.noneOf(Model.class);
    private final String failureMessage;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final LinkedBlockingDeque<Runnable> synthesisQueue = new LinkedBlockingDeque<>();
    private final ThreadPoolExecutor worker = new ThreadPoolExecutor(
            1, 1, 0, TimeUnit.MILLISECONDS, synthesisQueue);
    private final ExecutorService cacheReader = Executors.newSingleThreadExecutor();
    private final ComputerSpeech computer = new ComputerSpeech();

    // The synthesizer belongs exclusively to the worker. Playback slots belong to main.
    private OfflineTts tts;
    private MossNarratorEngine broadcast;
    private Model loadedModel;
    private Segment current;
    private final Map<Long, Segment> prepared = new LinkedHashMap<>();
    private Long lastSpokenId;
    private AudioTrack playing;

    private final class Segment implements Runnable {
        final long id;
        final String text;
        final float speed;
        final Voice voice;
        final List<URI> computerAddresses;
        volatile boolean cancelled;
        volatile boolean cacheToDisk;
        Consumer<Boolean> preparation;
        IntConsumer progress;
        Consumer<String> completion;
        BufferedSpeech ready;
        boolean retryOnPreparationFailure;

        Segment(long id, String text, float speed, Voice voice, List<URI> computerAddresses) {
            this.id = id;
            this.text = text;
            this.speed = speed;
            this.voice = voice;
            this.computerAddresses = computerAddresses;
        }

        boolean matchesSettings(float speed, Voice voice, List<URI> computerAddresses) {
            return this.speed == speed && this.voice == voice
                    && this.computerAddresses.equals(computerAddresses);
        }

        @Override
        public void run() {
            synthesize(this);
        }
    }

    private static final class BufferedSpeech {
        final short[] pcm;
        final File file;
        final int frames;
        final int sampleRate;
        final String failure;

        BufferedSpeech(short[] pcm, File file, int frames, int sampleRate, String failure) {
            this.pcm = pcm;
            this.file = file;
            this.frames = frames;
            this.sampleRate = sampleRate;
            this.failure = failure;
        }

        void release() {
            if (file != null) deleteCacheFile(file);
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
        modelStorage = context.getNoBackupFilesDir();
        speechCache = new File(context.getCacheDir(), "narration");
        failureMessage = context.getString(R.string.tts_offline_failed);
        for (Model model : Model.values()) {
            if (modelAssetsAvailable(assets, model)) available.add(model);
        }
    }

    boolean isAvailable(Voice voice) {
        return available.contains(voice.model);
    }

    boolean isAvailable(Voice voice, List<URI> computerAddresses) {
        return voice == Voice.COMPUTER ? !computerAddresses.isEmpty() : isAvailable(voice);
    }

    Voice selectVoice(String id) {
        if (id == null || Voice.CLEAR.id.equals(id)) {
            return isAvailable(Voice.CLEAR) ? Voice.CLEAR : Voice.FIRST;
        }
        return Voice.select(id);
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

    private MossNarratorEngine broadcastSynthesizer() throws IOException, JSONException, OrtException {
        if (broadcast != null) return broadcast;
        releaseSynthesizer();
        Model model = Model.BROADCAST;
        // ONNX graphs share external weights. They need ordinary files in the same directory.
        File directory = new File(modelStorage, model.directory);
        if (!directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("Could not prepare broadcast voice storage");
        }
        for (String name : model.requiredFiles) {
            File destination = new File(directory, name);
            if (destination.isFile()) continue;
            File temporary = File.createTempFile("voice-", ".tmp", directory);
            try {
                try (InputStream source = assets.open(model.path(name), AssetManager.ACCESS_STREAMING);
                     FileOutputStream output = new FileOutputStream(temporary)) {
                    byte[] buffer = new byte[256 * 1024];
                    int count;
                    while ((count = source.read(buffer)) != -1) output.write(buffer, 0, count);
                }
                if (!temporary.renameTo(destination) && !destination.isFile()) {
                    throw new IOException("Could not install broadcast voice component " + name);
                }
            } finally {
                temporary.delete();
            }
        }
        broadcast = new MossNarratorEngine(directory);
        return broadcast;
    }

    private void releaseSynthesizer() {
        OfflineTts previous = tts;
        tts = null;
        loadedModel = null;
        if (previous != null) previous.release();
        if (broadcast != null) {
            broadcast.close();
            broadcast = null;
        }
    }

    boolean prepare(long id, String text, float speed, Voice voice, List<URI> computerAddresses,
                    Consumer<Boolean> onPrepared) {
        if ((lastSpokenId != null && id <= lastSpokenId) || prepared.containsKey(id)
                || (current != null && !current.matchesSettings(speed, voice, computerAddresses))) {
            return false;
        }
        Segment segment = new Segment(id, text, speed, voice, computerAddresses);
        segment.cacheToDisk = true;
        segment.preparation = onPrepared;
        segment.retryOnPreparationFailure = true;
        prepared.put(id, segment);
        worker.execute(segment);
        return true;
    }

    void speak(long id, String text, float speed, Voice voice, List<URI> computerAddresses,
               IntConsumer progress, Consumer<String> completion) {
        discard(current);
        stopTrack();
        lastSpokenId = id;
        Segment next = prepared.remove(id);
        if (next != null && next.text.equals(text) && next.matchesSettings(speed, voice, computerAddresses)) {
            if (Log.isLoggable(TAG, Log.DEBUG)
                    && (next.ready == null || next.ready.frames > 0)) {
                Log.d(TAG, next.ready == null ? "Reused in-flight segment" : "Reused buffered segment");
            }
            prepared.values().removeIf(segment -> {
                if (segment.id > id && segment.matchesSettings(speed, voice, computerAddresses)) return false;
                discard(segment);
                return true;
            });
            current = next;
            current.cacheToDisk = false;
            current.progress = progress;
            current.completion = completion;
            playWhenReady(next);
        } else {
            discard(next);
            discardPrepared();
            current = new Segment(id, text, speed, voice, computerAddresses);
            current.progress = progress;
            current.completion = completion;
            worker.execute(current);
        }
    }

    private void synthesize(Segment segment) {
        if (segment.cancelled) return;
        boolean computerVoice = segment.voice == Voice.COMPUTER;
        try {
            if ((computerVoice || segment.voice == Voice.CLEAR)
                    && segment.text.codePoints().noneMatch(Character::isLetterOrDigit)) {
                publish(segment, new BufferedSpeech(null, null, 0, 0, null));
                return;
            }
            if (computerVoice) {
                releaseSynthesizer();
                short[] pcm = computer.fetch(segment.computerAddresses, segment.text, () -> segment.cancelled);
                if (pcm != null) publishPcm(segment, pcm, ComputerSpeech.SAMPLE_RATE);
            } else {
                synthesizeLocal(segment);
            }
        } catch (IOException | JSONException | OrtException | RuntimeException | LinkageError failure) {
            if (!segment.cancelled) {
                Log.w(TAG, "Could not synthesize or cache audio", failure);
                publish(segment, new BufferedSpeech(null, null, 0, 0,
                        computerVoice ? COMPUTER_FAILURE : failureMessage));
            }
        }
    }

    private void synthesizeLocal(Segment segment) throws IOException, JSONException, OrtException {
        float[] samples;
        int sampleRate;
        if (segment.voice == Voice.CLEAR) {
            long started = SystemClock.elapsedRealtime();
            MossNarratorEngine model = broadcastSynthesizer();
            if (segment.cancelled) return;
            samples = model.synthesize(segment.text, () -> segment.cancelled);
            sampleRate = model.sampleRate();
            if (Log.isLoggable(TAG, Log.DEBUG)) {
                Log.d(TAG, "Broadcast synthesis ms=" + (SystemClock.elapsedRealtime() - started)
                        + " audioMs=" + (samples.length * 1000L / sampleRate));
            }
        } else {
            OfflineTts model = synthesizer(segment.voice);
            if (segment.cancelled) return;
            if (segment.voice.speakerId >= model.numSpeakers()) {
                throw new IllegalStateException("Selected speaker is missing from the model");
            }
            GeneratedAudio audio = model.generateWithCallback(segment.text, segment.voice.speakerId,
                    segment.speed, new SynthesisCancellation(segment));
            samples = audio.getSamples();
            sampleRate = audio.getSampleRate();
        }
        if (segment.cancelled) return;
        if (samples.length == 0 || sampleRate <= 0) {
            if (segment.text.codePoints().noneMatch(Character::isLetterOrDigit)) {
                publish(segment, new BufferedSpeech(null, null, 0, 0, null));
                return;
            }
            throw new IllegalStateException("No speech samples generated");
        }
        short[] pcm = new short[samples.length];
        for (int i = 0; i < samples.length; i++) {
            pcm[i] = (short) Math.round(Math.max(-1f, Math.min(1f, samples[i])) * 32767f);
        }
        publishPcm(segment, pcm, sampleRate);
    }

    private void publishPcm(Segment segment, short[] pcm, int sampleRate) throws IOException {
        if (segment.cancelled) return;
        if (segment.cacheToDisk) {
            File file = writeCache(segment, pcm);
            if (file != null) publish(segment, new BufferedSpeech(null, file, pcm.length, sampleRate, null));
        } else {
            publish(segment, new BufferedSpeech(pcm, null, pcm.length, sampleRate, null));
        }
    }

    private static void deleteCacheFile(File file) {
        if (!file.delete() && file.exists()) Log.w(TAG, "Could not delete an audio cache file");
    }

    private void ensureSpeechCache() throws IOException {
        if (!speechCache.isDirectory() && !speechCache.mkdirs() && !speechCache.isDirectory()) {
            throw new IOException("Could not create speech cache directory");
        }
        synchronized (CACHE_SETUP_LOCK) {
            if (checkedSpeechCache) return;
            // No narrator from the previous process can still own these files.
            File[] stale = speechCache.listFiles((directory, name) -> name.matches("segment-[0-9]+\\.pcm"));
            if (stale == null) throw new IOException("Could not list speech cache files");
            for (File file : stale) if (file.isFile()) deleteCacheFile(file);
            checkedSpeechCache = true;
        }
    }

    private File writeCache(Segment segment, short[] pcm) throws IOException {
        ensureSpeechCache();
        File file = File.createTempFile("segment-", ".pcm", speechCache);
        boolean saved = false;
        try {
            try (FileOutputStream output = new FileOutputStream(file)) {
                ByteBuffer block = ByteBuffer.allocate(PCM_BLOCK_SAMPLES * Short.BYTES)
                        .order(ByteOrder.LITTLE_ENDIAN);
                for (int i = 0; i < pcm.length; i += PCM_BLOCK_SAMPLES) {
                    if (segment.cancelled) return null;
                    int frames = Math.min(PCM_BLOCK_SAMPLES, pcm.length - i);
                    block.asShortBuffer().put(pcm, i, frames);
                    output.write(block.array(), 0, frames * Short.BYTES);
                }
            }
            saved = true;
            return file;
        } finally {
            if (!saved) deleteCacheFile(file);
        }
    }

    private void loadCache(Segment segment, BufferedSpeech audio) {
        cacheReader.execute(() -> {
            try {
                if (segment.cancelled) return;
                if (audio.file.length() != (long) audio.frames * Short.BYTES) {
                    throw new IOException("Missing or incomplete cached speech");
                }
                short[] pcm = new short[audio.frames];
                ByteBuffer block = ByteBuffer.allocate(PCM_BLOCK_SAMPLES * Short.BYTES)
                        .order(ByteOrder.LITTLE_ENDIAN);
                try (DataInputStream input = new DataInputStream(new FileInputStream(audio.file))) {
                    for (int i = 0; i < pcm.length; i += PCM_BLOCK_SAMPLES) {
                        if (segment.cancelled) return;
                        int frames = Math.min(PCM_BLOCK_SAMPLES, pcm.length - i);
                        input.readFully(block.array(), 0, frames * Short.BYTES);
                        block.asShortBuffer().get(pcm, i, frames);
                    }
                }
                publish(segment, new BufferedSpeech(pcm, null, pcm.length, audio.sampleRate, null));
            } catch (IOException | RuntimeException failure) {
                if (!segment.cancelled) {
                    Log.w(TAG, "Could not read cached speech", failure);
                    publish(segment, new BufferedSpeech(null, null, 0, 0, failureMessage));
                }
            } finally {
                audio.release();
            }
        });
    }

    private void publish(Segment segment, BufferedSpeech audio) {
        if (!main.post(() -> {
            if (segment.cancelled || (segment != current && prepared.get(segment.id) != segment)) {
                audio.release();
                return;
            }
            segment.ready = audio;
            if (segment == current) {
                playWhenReady(segment);
            } else {
                segment.preparation.accept(audio.failure == null);
                if (audio.frames > 0 && Log.isLoggable(TAG, Log.DEBUG)) {
                    Log.d(TAG, "Buffered next narration segment");
                }
            }
        })) audio.release();
    }

    private void playWhenReady(Segment segment) {
        BufferedSpeech audio = segment.ready;
        if (audio == null) return;
        segment.ready = null;
        if (audio.file != null) {
            loadCache(segment, audio);
            return;
        }
        if (audio.pcm == null) {
            if (audio.failure != null && segment.retryOnPreparationFailure) {
                segment.retryOnPreparationFailure = false;
                // The core worker is already running. Retry before queued lookahead.
                synthesisQueue.addFirst(segment);
                return;
            }
            complete(segment, audio.failure);
            return;
        }
        short[] pcm = audio.pcm;
        int frameCount = pcm.length;
        try {
            AudioTrack track = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build())
                    .setAudioFormat(new AudioFormat.Builder()
                            .setSampleRate(audio.sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build())
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .setBufferSizeInBytes(frameCount * Short.BYTES)
                    .build();
            playing = track;
            if (track.write(pcm, 0, frameCount, AudioTrack.WRITE_BLOCKING) != frameCount) {
                throw new IllegalStateException("Incomplete speech audio buffer");
            }
            track.setPlaybackPositionUpdateListener(new AudioTrack.OnPlaybackPositionUpdateListener() {
                @Override
                public void onMarkerReached(AudioTrack ended) {
                    finish(segment, ended, null);
                }

                @Override
                public void onPeriodicNotification(AudioTrack ignored) {}
            }, main);
            track.setNotificationMarkerPosition(frameCount);
            if ((segment.voice == Voice.CLEAR || segment.voice == Voice.COMPUTER)
                    && segment.speed != 1f) {
                track.setPlaybackParams(new PlaybackParams().setPitch(1f).setSpeed(segment.speed));
            }
            track.play();
            segment.progress.accept(0);
            long deadline = SystemClock.uptimeMillis()
                    + frameCount * 1000L / audio.sampleRate + 5000;
            // Some devices miss a marker at the exact last frame. Check the actual head as a fallback.
            main.postDelayed(new Runnable() {
                private int lastOffset;

                @Override
                public void run() {
                    if (segment != current || playing != track) return;
                    int head = track.getPlaybackHeadPosition();
                    if (head >= frameCount) {
                        finish(segment, track, null);
                    } else if (SystemClock.uptimeMillis() >= deadline) {
                        finish(segment, track, failureMessage);
                    } else {
                        // shortcut: Offline voices have no word times, so estimate from rendered frames.
                        int offset = (int) ((long) head * segment.text.length() / frameCount);
                        if (offset > lastOffset) {
                            lastOffset = offset;
                            segment.progress.accept(offset);
                        }
                        main.postDelayed(this, 250);
                    }
                }
            }, 250);
        } catch (RuntimeException failure) {
            Log.w(TAG, "Could not play speech audio", failure);
            finish(segment, playing, failureMessage);
        }
    }

    private void complete(Segment segment, String message) {
        if (segment != current) return;
        current = null;
        if (message != null) {
            lastSpokenId = null;
            discardPrepared();
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

    private void discardPrepared() {
        for (Segment segment : prepared.values()) discard(segment);
        prepared.clear();
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
        discardPrepared();
        current = null;
        lastSpokenId = null;
        stopTrack();
    }

    @Override
    public void close() {
        stop();
        worker.execute(this::releaseSynthesizer);
        worker.shutdown();
        cacheReader.shutdown();
    }
}
