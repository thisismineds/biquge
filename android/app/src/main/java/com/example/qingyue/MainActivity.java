package com.example.qingyue;

import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.media.AudioAttributes;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;
import android.util.Log;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Consumer;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static MainActivity backgroundOwner;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Consumer<TextToSpeech>> waiting = new ArrayList<>();
    private MethodChannel speech;
    private OfflineNarrator offline;
    private TextToSpeech engine;
    private boolean ready;
    private long engineGeneration;
    private long speechGeneration;
    private Number activeId;
    private String activeToken;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        offline = new OfflineNarrator(getApplicationContext());
        speech = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "qingyue/tts");
        speech.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "voices":
                    withEngine(readyEngine -> {
                        List<Map<String, Object>> voices = new ArrayList<>();
                        if (offline != null && offline.isAvailable()) {
                            for (OfflineNarrator.Voice voice : OfflineNarrator.Voice.values()) {
                                voices.add(voiceEntry(voice.id, voice.name, false));
                            }
                        }
                        if (readyEngine != null) {
                            for (Voice voice : chineseVoices(readyEngine)) {
                                voices.add(voiceEntry(voice.getName(), getString(R.string.tts_voice_label,
                                        voice.getLocale().getDisplayName(Locale.SIMPLIFIED_CHINESE),
                                        voice.getName()), voice.isNetworkConnectionRequired()));
                            }
                        }
                        result.success(voices);
                    });
                    break;
                case "speak":
                    speak(call.argument("id"), call.argument("text"), call.argument("rate"),
                            call.argument("voice"), result);
                    break;
                case "prepare":
                    prepare(call.argument("id"), call.argument("text"), call.argument("rate"),
                            call.argument("voice"));
                    result.success(null);
                    break;
                case "stop":
                    stopSpeech();
                    result.success(null);
                    break;
                case "installVoices":
                    installVoices(result);
                    break;
                case "beginBackground":
                    setBackground(call, result, true);
                    break;
                case "updateBackground":
                    setBackground(call, result, false);
                    break;
                case "endBackground":
                    endBackground();
                    result.success(null);
                    break;
                default:
                    result.notImplemented();
            }
        });
    }

    private void setBackground(MethodCall call, MethodChannel.Result result, boolean begin) {
        Object book = call.argument("book");
        Object chapter = call.argument("chapter");
        Object playing = begin ? Boolean.TRUE : call.argument("playing");
        if (!(book instanceof String) || !(chapter instanceof String)
                || !(playing instanceof Boolean)) {
            result.error("invalid_background", "听书信息无效，请重新开始播放。", null);
            return;
        }
        if (!begin && backgroundOwner != this) {
            result.error("background_inactive", "后台听书已结束，请重新开始播放。", null);
            return;
        }
        try {
            if (begin && backgroundOwner != this) {
                if (backgroundOwner != null) backgroundOwner.endBackground();
                backgroundOwner = this;
                NarrationService.setControls(this::onTransport);
            }
            NarrationService.update(getApplicationContext(), (String) book, (String) chapter,
                    (Boolean) playing);
            result.success(null);
        } catch (RuntimeException failure) {
            Log.w("QingyueNarration", "Unable to start or update playback service", failure);
            if (!begin) onTransport("stop");
            endBackground();
            result.error("background_service", "无法开启后台听书，请回到阅读页重试。", null);
        }
    }

    private void onTransport(String action) {
        if (backgroundOwner != this || speech == null) return;
        if (!"play".equals(action) && !"pause".equals(action) && !"stop".equals(action)) return;
        if ("stop".equals(action)) stopSpeech();
        speech.invokeMethod("transport", Collections.singletonMap("action",
                "play".equals(action) ? "resume" : action));
    }

    private void endBackground() {
        if (backgroundOwner != this) return;
        backgroundOwner = null;
        NarrationService.setControls(null);
        try {
            NarrationService.stop(getApplicationContext());
        } catch (RuntimeException failure) {
            Log.w("QingyueNarration", "Unable to stop playback service", failure);
        }
    }

    private static Map<String, Object> voiceEntry(String id, String label, boolean networkRequired) {
        Map<String, Object> entry = new HashMap<>();
        entry.put("id", id);
        entry.put("label", label);
        entry.put("networkRequired", networkRequired);
        return entry;
    }

    private void withEngine(Consumer<TextToSpeech> action) {
        if (ready) {
            action.accept(engine);
            return;
        }
        waiting.add(action);
        if (engine != null) return;
        long generation = ++engineGeneration;
        // An engine may report failure before its constructor returns.
        engine = new TextToSpeech(getApplicationContext(),
                status -> main.post(() -> finishInit(generation, status)));
        main.postDelayed(() -> finishInit(generation, TextToSpeech.ERROR), 10000);
    }

    private void finishInit(long generation, int status) {
        if (generation != engineGeneration || ready) return;
        ready = status == TextToSpeech.SUCCESS;
        if (ready) {
            engine.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build());
            engine.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                @Override
                public void onStart(String token) {}

                @Override
                public void onDone(String token) {
                    notifyDart(token, null);
                }

                @Override
                public void onError(String token) {
                    notifyDart(token, getString(R.string.tts_synthesis_failed));
                }

                @Override
                public void onError(String token, int code) {
                    notifyDart(token, getString(code == TextToSpeech.ERROR_NOT_INSTALLED_YET
                            ? R.string.tts_voice_unavailable : R.string.tts_synthesis_failed));
                }

                @Override
                public void onStop(String token, boolean interrupted) {
                    notifyDart(token, getString(R.string.tts_interrupted));
                }
            });
        } else {
            engineGeneration++;
            if (engine != null) engine.shutdown();
            engine = null;
        }
        List<Consumer<TextToSpeech>> actions = new ArrayList<>(waiting);
        waiting.clear();
        for (Consumer<TextToSpeech> action : actions) action.accept(engine);
    }

    private static List<Voice> chineseVoices(TextToSpeech engine) {
        List<Voice> voices = new ArrayList<>();
        Set<Voice> available = engine.getVoices();
        if (available != null) {
            for (Voice voice : available) {
                Set<String> features = voice.getFeatures();
                if ("zh".equals(voice.getLocale().getLanguage())
                        && (features == null
                        || !features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED))) {
                    voices.add(voice);
                }
            }
        }
        voices.sort(Comparator
                .comparing(Voice::isNetworkConnectionRequired)
                .thenComparing(voice -> !"CN".equals(voice.getLocale().getCountry()))
                .thenComparing(Voice::getName));
        return voices;
    }

    private static boolean validSpeech(Number id, String text, Number rate) {
        return id != null && text != null && !text.trim().isEmpty()
                && text.length() <= TextToSpeech.getMaxSpeechInputLength()
                && (rate == null || (Float.isFinite(rate.floatValue()) && rate.floatValue() > 0));
    }

    private void prepare(Number id, String text, Number rate, String voiceId) {
        OfflineNarrator.Voice voice = OfflineNarrator.Voice.select(voiceId);
        if (voice != null && offline != null && offline.isAvailable() && validSpeech(id, text, rate)) {
            offline.prepare(id.longValue(), text, rate == null ? 1f : rate.floatValue(), voice);
        }
    }

    private void speak(Number id, String text, Number rate, String voiceId, MethodChannel.Result result) {
        if (!validSpeech(id, text, rate)) {
            result.error("invalid_speech", getString(R.string.tts_invalid_speech), null);
            return;
        }
        resetSpeechCallback();
        long generation = speechGeneration;
        OfflineNarrator.Voice offlineVoice = OfflineNarrator.Voice.select(voiceId);
        if (offlineVoice != null) {
            if (offline == null || !offline.isAvailable()) {
                result.error("voice", getString(R.string.tts_offline_failed), null);
                return;
            }
            String token = Long.toString(generation);
            activeId = id;
            activeToken = token;
            offline.speak(id.longValue(), text, rate == null ? 1f : rate.floatValue(), offlineVoice,
                    message -> notifyDart(token, message));
            result.success(null);
            return;
        }
        if (offline != null) offline.stop();
        withEngine(readyEngine -> {
            if (generation != speechGeneration) {
                result.success(null);
                return;
            }
            if (readyEngine == null) {
                result.error("engine", getString(R.string.tts_engine_unavailable), null);
                return;
            }
            boolean languageReady = chineseVoices(readyEngine).stream().anyMatch(voice ->
                    voiceId.equals(voice.getName())
                            && readyEngine.setVoice(voice) == TextToSpeech.SUCCESS);
            if (!languageReady) {
                result.error("voice", getString(R.string.tts_voice_unavailable), null);
                return;
            }
            String token = Long.toString(generation);
            activeId = id;
            activeToken = token;
            if (readyEngine.setSpeechRate(rate == null ? 1f : rate.floatValue()) != TextToSpeech.SUCCESS
                    || readyEngine.speak(text, TextToSpeech.QUEUE_FLUSH, null, token) != TextToSpeech.SUCCESS) {
                stopSpeech();
                result.error("speak", getString(R.string.tts_synthesis_failed), null);
            } else {
                result.success(null);
            }
        });
    }

    private void notifyDart(String token, String message) {
        main.post(() -> {
            if (speech == null || token == null || !token.equals(activeToken)) return;
            Number id = activeId;
            activeId = null;
            activeToken = null;
            Map<String, Object> event = new HashMap<>();
            event.put("id", id);
            if (message != null) event.put("message", message);
            speech.invokeMethod(message == null ? "finished" : "error", event);
        });
    }

    private void resetSpeechCallback() {
        speechGeneration++;
        activeId = null;
        activeToken = null;
        if (engine != null && ready) engine.stop();
    }

    private void stopSpeech() {
        resetSpeechCallback();
        if (offline != null) offline.stop();
    }

    private void installVoices(MethodChannel.Result result) {
        Intent install = new Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA);
        String preferred = engine == null ? null : engine.getDefaultEngine();
        if (preferred != null) install.setPackage(preferred);

        // Android Settings exposes this action on AOSP and compatible devices.
        Intent settings = new Intent("com.android.settings.TTS_SETTINGS")
                .setPackage("com.android.settings");
        if (!launchVoiceActivity(install) && !launchVoiceActivity(settings)) {
            result.error("voice_settings", getString(R.string.tts_install_unavailable), null);
            return;
        }
        releaseEngine();
        result.success(null);
    }

    private boolean launchVoiceActivity(Intent intent) {
        try {
            startActivity(intent);
            return true;
        } catch (ActivityNotFoundException | SecurityException unavailable) {
            return false;
        }
    }

    private void releaseEngine() {
        stopSpeech();
        engineGeneration++;
        if (engine != null) engine.shutdown();
        engine = null;
        ready = false;
        List<Consumer<TextToSpeech>> actions = new ArrayList<>(waiting);
        waiting.clear();
        main.removeCallbacksAndMessages(null);
        for (Consumer<TextToSpeech> action : actions) action.accept(null);
    }

    @Override
    public void cleanUpFlutterEngine(FlutterEngine flutterEngine) {
        endBackground();
        if (speech != null) speech.setMethodCallHandler(null);
        speech = null;
        releaseEngine();
        if (offline != null) offline.close();
        offline = null;
        super.cleanUpFlutterEngine(flutterEngine);
    }
}
