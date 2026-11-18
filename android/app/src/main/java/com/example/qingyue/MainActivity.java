package com.example.qingyue;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.net.URI;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static MainActivity backgroundOwner;
    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel speech;
    private ComputerNarrator narrator;
    private long speechGeneration;
    private Number activeId;
    private String activeToken;
    private int lastProgressOffset = -1;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        narrator = new ComputerNarrator(getApplicationContext());
        speech = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "qingyue/tts");
        speech.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "speak":
                    speak(call.argument("id"), call.argument("text"), call.argument("rate"),
                            ComputerSpeech.addresses(call.argument("computerAddresses")),
                            result);
                    break;
                case "prepare":
                    prepare(call.argument("id"), call.argument("text"), call.argument("rate"),
                            ComputerSpeech.addresses(call.argument("computerAddresses")));
                    result.success(null);
                    break;
                case "setSystemSpeechServers":
                    Object addresses = call.argument("computerAddresses");
                    if (!(addresses instanceof List<?>)) {
                        result.error("invalid_computer_addresses",
                                getString(R.string.tts_computer_address), null);
                        break;
                    }
                    SystemSpeechService.saveServers(this, (List<?>) addresses);
                    result.success(null);
                    break;
                case "stop":
                    stopSpeech();
                    result.success(null);
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

    private static boolean validSpeech(Number id, String text, Number rate) {
        return id != null && ComputerSpeech.validText(text)
                && (rate == null || (Float.isFinite(rate.floatValue()) && rate.floatValue() > 0));
    }

    private void prepare(Number id, String text, Number rate, List<URI> computerAddresses) {
        if (!validSpeech(id, text, rate) || computerAddresses.isEmpty()
                || !narrator.prepare(id.longValue(), text, rate == null ? 1f : rate.floatValue(),
                        computerAddresses, ok -> notifyPrepared(id, ok))) {
            notifyPrepared(id, false);
        }
    }

    private void notifyPrepared(Number id, boolean ok) {
        if (speech == null || id == null) return;
        Map<String, Object> event = new HashMap<>();
        event.put("id", id);
        event.put("ok", ok);
        speech.invokeMethod("prepared", event);
    }

    private void speak(Number id, String text, Number rate, List<URI> computerAddresses,
                       MethodChannel.Result result) {
        if (!validSpeech(id, text, rate)) {
            result.error("invalid_speech", getString(R.string.tts_invalid_speech), null);
            return;
        }
        if (computerAddresses.isEmpty()) {
            result.error("computer_address", getString(R.string.tts_computer_address), null);
            return;
        }
        resetSpeechCallback();
        String token = Long.toString(speechGeneration);
        activeId = id;
        activeToken = token;
        narrator.speak(id.longValue(), text, rate == null ? 1f : rate.floatValue(),
                computerAddresses, offset -> notifyProgress(token, offset),
                message -> notifyDart(token, message));
        result.success(null);
    }

    private void notifyProgress(String token, int offset) {
        main.post(() -> {
            if (speech == null || token == null || !token.equals(activeToken)
                    || offset <= lastProgressOffset) return;
            lastProgressOffset = offset;
            Map<String, Object> event = new HashMap<>();
            event.put("id", activeId);
            event.put("offset", offset);
            speech.invokeMethod("progress", event);
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
        lastProgressOffset = -1;
    }

    private void stopSpeech() {
        resetSpeechCallback();
        if (narrator != null) narrator.stop();
    }

    @Override
    public void cleanUpFlutterEngine(FlutterEngine flutterEngine) {
        endBackground();
        if (speech != null) speech.setMethodCallHandler(null);
        speech = null;
        resetSpeechCallback();
        main.removeCallbacksAndMessages(null);
        if (narrator != null) narrator.close();
        narrator = null;
        super.cleanUpFlutterEngine(flutterEngine);
    }
}
