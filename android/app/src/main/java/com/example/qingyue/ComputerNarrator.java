package com.example.qingyue;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.PlaybackParams;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import org.json.JSONException;

import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
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

final class ComputerNarrator implements AutoCloseable {
    private static final String TAG = "QingyueNarration";
    private static final String COMPUTER_FAILURE =
            "电脑合成未能返回音频。请确认服务已启动、地址正确，且手机与电脑连接同一局域网。";
    private static final int PCM_BLOCK_SAMPLES = 32768;
    private static final Object CACHE_SETUP_LOCK = new Object();
    private static boolean checkedSpeechCache;

    private final File speechCache;
    private final String failureMessage;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final LinkedBlockingDeque<Runnable> synthesisQueue = new LinkedBlockingDeque<>();
    private final ThreadPoolExecutor worker = new ThreadPoolExecutor(
            1, 1, 0, TimeUnit.MILLISECONDS, synthesisQueue);
    private final ExecutorService cacheReader = Executors.newSingleThreadExecutor();
    private final ComputerSpeech computer = new ComputerSpeech();

    private Segment current;
    private final Map<Long, Segment> prepared = new LinkedHashMap<>();
    private Long lastSpokenId;
    private AudioTrack playing;

    private final class Segment implements Runnable {
        final long id;
        final String text;
        final float speed;
        final List<URI> computerAddresses;
        volatile boolean cancelled;
        volatile boolean cacheToDisk;
        Consumer<Boolean> preparation;
        IntConsumer progress;
        Consumer<String> completion;
        BufferedSpeech ready;
        boolean retryOnPreparationFailure;

        Segment(long id, String text, float speed, List<URI> computerAddresses) {
            this.id = id;
            this.text = text;
            this.speed = speed;
            this.computerAddresses = computerAddresses;
        }

        boolean matchesSettings(float speed, List<URI> computerAddresses) {
            return this.speed == speed && this.computerAddresses.equals(computerAddresses);
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

    ComputerNarrator(Context context) {
        speechCache = new File(context.getCacheDir(), "narration");
        failureMessage = context.getString(R.string.tts_playback_failed);
        File noBackup = context.getNoBackupFilesDir();
        worker.execute(() -> removeExtractedVoice(noBackup));
    }

    private static void removeExtractedVoice(File noBackup) {
        File directory = new File(noBackup, "tts/broadcast-moss-v1");
        try {
            // Old versions only wrote model files directly under this app-private folder.
            if (!directory.getCanonicalFile().equals(
                    new File(noBackup.getCanonicalFile(), "tts/broadcast-moss-v1"))) return;
            File[] files = directory.listFiles();
            if (files == null) return;
            for (File file : files) {
                if (file.isFile() && !file.delete() && file.exists()) {
                    Log.w(TAG, "Could not remove an old voice model file");
                }
            }
            directory.delete();
        } catch (IOException failure) {
            Log.w(TAG, "Could not resolve the old voice model directory", failure);
        }
    }

    boolean prepare(long id, String text, float speed, List<URI> computerAddresses,
                    Consumer<Boolean> onPrepared) {
        if ((lastSpokenId != null && id <= lastSpokenId) || prepared.containsKey(id)
                || (current != null && !current.matchesSettings(speed, computerAddresses))) {
            return false;
        }
        Segment segment = new Segment(id, text, speed, computerAddresses);
        segment.cacheToDisk = true;
        segment.preparation = onPrepared;
        segment.retryOnPreparationFailure = true;
        prepared.put(id, segment);
        worker.execute(segment);
        return true;
    }

    void speak(long id, String text, float speed, List<URI> computerAddresses,
               IntConsumer progress, Consumer<String> completion) {
        discard(current);
        stopTrack();
        lastSpokenId = id;
        Segment next = prepared.remove(id);
        if (next != null && next.text.equals(text) && next.matchesSettings(speed, computerAddresses)) {
            if (Log.isLoggable(TAG, Log.DEBUG)
                    && (next.ready == null || next.ready.frames > 0)) {
                Log.d(TAG, next.ready == null ? "Reused in-flight segment" : "Reused buffered segment");
            }
            prepared.values().removeIf(segment -> {
                if (segment.id > id && segment.matchesSettings(speed, computerAddresses)) return false;
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
            current = new Segment(id, text, speed, computerAddresses);
            current.progress = progress;
            current.completion = completion;
            worker.execute(current);
        }
    }

    private void synthesize(Segment segment) {
        if (segment.cancelled) return;
        try {
            if (segment.text.codePoints().noneMatch(Character::isLetterOrDigit)) {
                publish(segment, new BufferedSpeech(null, null, 0, 0, null));
                return;
            }
            short[] pcm = computer.fetch(segment.computerAddresses, segment.text, () -> segment.cancelled);
            if (pcm != null) publishPcm(segment, pcm, ComputerSpeech.SAMPLE_RATE);
        } catch (IOException | JSONException | RuntimeException failure) {
            if (!segment.cancelled) {
                Log.w(TAG, "Could not synthesize or cache audio", failure);
                publish(segment, new BufferedSpeech(null, null, 0, 0, COMPUTER_FAILURE));
            }
        }
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
            if (segment.speed != 1f) {
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
                        // shortcut: The speech server provides no word times, so estimate from rendered frames.
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
        worker.shutdown();
        cacheReader.shutdown();
    }
}
