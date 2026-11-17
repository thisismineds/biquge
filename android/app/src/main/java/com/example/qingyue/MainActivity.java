package com.example.qingyue;

import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.media.AudioAttributes;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Consumer;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Consumer<TextToSpeech>> waiting = new ArrayList<>();
    private MethodChannel speech;
    private TextToSpeech engine;
    private boolean ready;
    private long engineGeneration;
    private long speechGeneration;
    private Number activeId;
    private String activeToken;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        speech = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "qingyue/tts");
        speech.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "voices":
                    withEngine(readyEngine -> {
                        if (readyEngine == null) {
                            result.error("engine", getString(R.string.tts_engine_unavailable), null);
                            return;
                        }
                        List<Map<String, Object>> voices = new ArrayList<>();
                        for (Voice voice : chineseVoices(readyEngine)) {
                            Map<String, Object> entry = new HashMap<>();
                            entry.put("id", voice.getName());
                            entry.put("label", getString(R.string.tts_voice_label,
                                    voice.getLocale().getDisplayName(Locale.SIMPLIFIED_CHINESE),
                                    voice.getName()));
                            entry.put("networkRequired", voice.isNetworkConnectionRequired());
                            voices.add(entry);
                        }
                        result.success(voices);
                    });
                    break;
                case "speak":
                    speak(call.argument("id"), call.argument("text"), call.argument("rate"),
                            call.argument("voice"), result);
                    break;
                case "stop":
                    stopSpeech();
                    result.success(null);
                    break;
                case "installVoices":
                    installVoices(result);
                    break;
                default:
                    result.notImplemented();
            }
        });
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

    private void speak(Number id, String text, Number rate, String voiceId, MethodChannel.Result result) {
        if (id == null || text == null || text.trim().isEmpty()
                || text.length() > TextToSpeech.getMaxSpeechInputLength()
                || (rate != null && (!Float.isFinite(rate.floatValue()) || rate.floatValue() <= 0))) {
            result.error("invalid_speech", getString(R.string.tts_invalid_speech), null);
            return;
        }
        long generation = ++speechGeneration;
        withEngine(readyEngine -> {
            if (generation != speechGeneration) {
                result.success(null);
                return;
            }
            if (readyEngine == null) {
                result.error("engine", getString(R.string.tts_engine_unavailable), null);
                return;
            }
            List<Voice> voices = chineseVoices(readyEngine);
            boolean languageReady;
            if (voiceId != null) {
                languageReady = voices.stream().anyMatch(voice ->
                        voiceId.equals(voice.getName())
                                && readyEngine.setVoice(voice) == TextToSpeech.SUCCESS);
            } else {
                languageReady = voices.stream().anyMatch(voice ->
                        !voice.isNetworkConnectionRequired()
                                && readyEngine.setVoice(voice) == TextToSpeech.SUCCESS);
                if (!languageReady) {
                    languageReady = readyEngine.setLanguage(Locale.SIMPLIFIED_CHINESE) >= 0;
                }
            }
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

    private void stopSpeech() {
        speechGeneration++;
        activeId = null;
        activeToken = null;
        if (engine != null && ready) engine.stop();
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
        if (speech != null) speech.setMethodCallHandler(null);
        speech = null;
        releaseEngine();
        super.cleanUpFlutterEngine(flutterEngine);
    }
}
