package com.example.qingyue;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import java.util.function.Consumer;

public final class NarrationService extends Service {
    private static final String CHANNEL = "qingyue_narration";
    private static final String SESSION = "session";
    private static final String START = "start";
    private static final int NOTIFICATION_ID = 122;

    // All access is on the Android main thread, including media-control callbacks.
    private static NarrationService active;
    private static Consumer<String> controls;
    private static long nextSession;
    private static long startingSession;
    private static Playback requested;

    private static final class Playback {
        final long session;
        final String book;
        final String chapter;
        final boolean playing;

        Playback(long session, String book, String chapter, boolean playing) {
            this.session = session;
            this.book = book;
            this.chapter = chapter;
            this.playing = playing;
        }
    }

    private MediaSession media;
    private PowerManager.WakeLock wakeLock;
    private AudioManager audio;
    private AudioFocusRequest audioRequest;
    private boolean focused;
    private long session;
    private final AudioManager.OnAudioFocusChangeListener onFocus = change -> {
        if (change < 0 && focused) transport("pause");
    };
    private final BroadcastReceiver onNoisy = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(intent.getAction())) {
                transport("pause");
            }
        }
    };

    static void setControls(Consumer<String> listener) {
        controls = listener;
    }

    static void update(Context context, String book, String chapter, boolean playing) {
        if (requested != null) {
            requested = new Playback(requested.session, book, chapter, playing);
            if (active != null && active.session == requested.session) {
                active.applyPlayback(requested);
            }
            return;
        }
        if (startingSession != 0) {
            requested = new Playback(startingSession, book, chapter, playing);
            return;
        }
        startingSession = ++nextSession;
        requested = new Playback(startingSession, book, chapter, playing);
        Intent intent = new Intent(context, NarrationService.class)
                .setAction(START)
                .putExtra(SESSION, requested.session);
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (RuntimeException error) {
            startingSession = 0;
            requested = null;
            throw error;
        }
    }

    static void stop(Context context) {
        requested = null;
        // Android requires an accepted startForegroundService to promote before stopping.
        if (startingSession != 0) return;
        if (active != null) {
            active.releasePlaybackResources();
            active.media.setActive(false);
            active.stopForeground(STOP_FOREGROUND_REMOVE);
        }
        context.stopService(new Intent(context, NarrationService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        audio = getSystemService(AudioManager.class);
        wakeLock = getSystemService(PowerManager.class)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "qingyue:narration");
        wakeLock.setReferenceCounted(false);
        media = new MediaSession(this, "QingyueNarration");
        media.setSessionActivity(openApp());
        media.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { transport("play"); }
            @Override public void onPause() { transport("pause"); }
            @Override public void onStop() { transport("stop"); }
            @Override public void onCustomAction(String action, Bundle extras) {
                if ("stop".equals(action)) transport("stop");
            }
        }, new Handler(Looper.getMainLooper()));
        IntentFilter filter = new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(onNoisy, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(onNoisy, filter);
        }
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager.class).createNotificationChannel(
                    new NotificationChannel(CHANNEL, getString(R.string.narration_channel),
                            NotificationManager.IMPORTANCE_LOW));
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Playback state = requested;
        if (intent == null) {
            if (state == null && startingSession == 0) stopSelf(startId);
            return START_NOT_STICKY;
        }
        long intentSession = intent.getLongExtra(SESSION, 0);
        if (START.equals(intent.getAction())) {
            if (intentSession == startingSession) startingSession = 0;
            if (state == null || intentSession != state.session) {
                if (state == null) {
                    promote(new Playback(0, getString(R.string.narration_channel), "", false));
                    stopForeground(STOP_FOREGROUND_REMOVE);
                    stopSelf(startId);
                }
                return START_NOT_STICKY;
            }
            active = this;
            session = state.session;
            try {
                media.setActive(true);
                applyPlayback(state);
            } catch (RuntimeException error) {
                Log.w("QingyueNarration", "Could not start foreground playback", error);
                transport("stop");
            }
        } else if (active == this && state != null
                && session == state.session && intentSession == session) {
            String action = intent.getAction();
            if ("play".equals(action) || "pause".equals(action) || "stop".equals(action)) {
                transport(action);
            }
        } else if (state == null && startingSession == 0) {
            stopSelf(startId);
        }
        return START_NOT_STICKY;
    }

    private void applyPlayback(Playback state) {
        media.setMetadata(new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, state.book)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, state.chapter)
                .build());
        media.setPlaybackState(new PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
                        | PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_STOP)
                .addCustomAction("stop", getString(R.string.narration_stop),
                        R.drawable.ic_narration_stop)
                .setState(state.playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
                        PlaybackState.PLAYBACK_POSITION_UNKNOWN, state.playing ? 1f : 0f)
                .build());
        promote(state);
        if (state.playing) {
            if (!focused && !requestFocus()) {
                transport("pause");
            } else if (!wakeLock.isHeld()) {
                wakeLock.acquire();
            }
        } else {
            releasePlaybackResources();
        }
    }

    private void promote(Playback state) {
        Notification notice = notification(state);
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notice,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        } else {
            startForeground(NOTIFICATION_ID, notice);
        }
    }

    private Notification notification(Playback state) {
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        }
        return builder
                .setSmallIcon(R.drawable.ic_narration)
                .setContentTitle(state.book)
                .setContentText(state.chapter)
                .setContentIntent(openApp())
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setOngoing(true)
                .addAction(action(state.playing ? "pause" : "play", state.playing
                                ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play,
                        state.playing ? R.string.narration_pause : R.string.narration_play))
                .addAction(action("stop", R.drawable.ic_narration_stop, R.string.narration_stop))
                .setStyle(new Notification.MediaStyle()
                        .setMediaSession(media.getSessionToken())
                        .setShowActionsInCompactView(0, 1))
                .build();
    }

    private Notification.Action action(String name, int icon, int label) {
        Intent intent = new Intent(this, NarrationService.class)
                .setAction(name)
                .setData(Uri.parse("qingyue://narration/" + session + "/" + name))
                .putExtra(SESSION, session);
        return new Notification.Action.Builder(Icon.createWithResource(this, icon), getString(label),
                PendingIntent.getService(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)).build();
    }

    private PendingIntent openApp() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        return launch == null ? null : PendingIntent.getActivity(this, 0, launch,
                PendingIntent.FLAG_IMMUTABLE);
    }

    private boolean requestFocus() {
        int result;
        if (Build.VERSION.SDK_INT >= 26) {
            audioRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build())
                    .setWillPauseWhenDucked(true)
                    .setOnAudioFocusChangeListener(onFocus)
                    .build();
            result = audio.requestAudioFocus(audioRequest);
        } else {
            result = audio.requestAudioFocus(onFocus, AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN);
        }
        focused = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        return focused;
    }

    private void releasePlaybackResources() {
        if (wakeLock.isHeld()) wakeLock.release();
        if (!focused) return;
        focused = false;
        if (Build.VERSION.SDK_INT >= 26) {
            audio.abandonAudioFocusRequest(audioRequest);
            audioRequest = null;
        } else {
            audio.abandonAudioFocus(onFocus);
        }
    }

    private void transport(String action) {
        Playback state = requested;
        if (active != this || state == null || session != state.session) return;
        if (("pause".equals(action) && !state.playing) || ("play".equals(action) && state.playing)) {
            return;
        }
        if (controls != null) controls.accept(action);
        if ("stop".equals(action) || controls == null) stop(this);
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        transport("stop");
    }

    @Override
    public void onDestroy() {
        boolean interrupted = active == this && requested != null && requested.session == session;
        if (active == this) active = null;
        if (interrupted) requested = null;
        releasePlaybackResources();
        unregisterReceiver(onNoisy);
        media.release();
        super.onDestroy();
        if (interrupted && controls != null) controls.accept("stop");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
