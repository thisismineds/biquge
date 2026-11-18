package com.example.qingyue;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.AudioFormat;
import android.os.Bundle;
import android.speech.tts.SynthesisCallback;
import android.speech.tts.SynthesisRequest;
import android.speech.tts.TextToSpeech;
import android.speech.tts.TextToSpeechService;
import android.speech.tts.Voice;

import org.json.JSONArray;
import org.json.JSONException;

import java.io.IOException;
import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

public final class SystemSpeechService extends TextToSpeechService {
    private static final String PREFS = "qingyue_system_speech";
    private static final String ADDRESSES = "computer_addresses";
    private static final String VOICE_NAME = "zh-CN-qingyue";
    private static final Locale VOICE_LOCALE = Locale.SIMPLIFIED_CHINESE;
    private static final String LANGUAGE = VOICE_LOCALE.getISO3Language();
    private static final String COUNTRY = VOICE_LOCALE.getISO3Country();
    private static final Set<String> FEATURES = Collections.singleton(
            TextToSpeech.Engine.KEY_FEATURE_NETWORK_SYNTHESIS);
    private static final int MAX_SEGMENT_CODE_POINTS = 100;

    private final ComputerSpeech computer = new ComputerSpeech();
    private final AtomicInteger generation = new AtomicInteger();

    static void saveServers(Context context, List<?> configured) {
        JSONArray saved = new JSONArray();
        for (URI address : ComputerSpeech.addresses(configured)) saved.put(address.toString());
        context.getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putString(ADDRESSES, saved.toString()).apply();
    }

    private List<URI> loadServers() throws JSONException {
        String saved = getSharedPreferences(PREFS, MODE_PRIVATE).getString(ADDRESSES, "[]");
        JSONArray array = new JSONArray(saved);
        List<String> configured = new ArrayList<>(array.length());
        for (int i = 0; i < array.length(); i++) configured.add(array.getString(i));
        return ComputerSpeech.addresses(configured);
    }

    @Override
    protected String[] onGetLanguage() {
        return new String[]{LANGUAGE, COUNTRY, ""};
    }

    @Override
    protected int onIsLanguageAvailable(String language, String country, String variant) {
        if (!LANGUAGE.equalsIgnoreCase(language) && !"zh".equalsIgnoreCase(language)
                && !"chi".equalsIgnoreCase(language)) return TextToSpeech.LANG_NOT_SUPPORTED;
        return COUNTRY.equalsIgnoreCase(country) || "CN".equalsIgnoreCase(country)
                ? TextToSpeech.LANG_COUNTRY_AVAILABLE : TextToSpeech.LANG_AVAILABLE;
    }

    @Override
    protected int onLoadLanguage(String language, String country, String variant) {
        return onIsLanguageAvailable(language, country, variant);
    }

    @Override
    protected Set<String> onGetFeaturesForLanguage(String language, String country, String variant) {
        return onIsLanguageAvailable(language, country, variant) >= TextToSpeech.LANG_AVAILABLE
                ? FEATURES : Collections.emptySet();
    }

    @Override
    public List<Voice> onGetVoices() {
        return Collections.singletonList(new Voice(VOICE_NAME, VOICE_LOCALE, Voice.QUALITY_HIGH,
                Voice.LATENCY_HIGH, true, FEATURES));
    }

    @Override
    public String onGetDefaultVoiceNameFor(String language, String country, String variant) {
        return onIsLanguageAvailable(language, country, variant) >= TextToSpeech.LANG_AVAILABLE
                ? VOICE_NAME : null;
    }

    @Override
    public int onIsValidVoiceName(String name) {
        return VOICE_NAME.equals(name) ? TextToSpeech.SUCCESS : TextToSpeech.ERROR;
    }

    @Override
    public int onLoadVoice(String name) {
        return onIsValidVoiceName(name);
    }

    @Override
    protected void onStop() {
        generation.incrementAndGet();
    }

    @Override
    protected void onSynthesizeText(SynthesisRequest request, SynthesisCallback callback) {
        int requestGeneration = generation.get();
        BooleanSupplier cancelled = () -> generation.get() != requestGeneration;
        String text = request.getCharSequenceText().toString();
        try {
            List<URI> servers = loadServers();
            if (servers.isEmpty()) {
                callback.error(TextToSpeech.ERROR_NETWORK);
                return;
            }
            int samplesPerBuffer = callback.getMaxBufferSize() / Short.BYTES;
            if (samplesPerBuffer < 1) {
                callback.error(TextToSpeech.ERROR_OUTPUT);
                return;
            }
            if (callback.start(ComputerSpeech.SAMPLE_RATE, AudioFormat.ENCODING_PCM_16BIT, 1)
                    != TextToSpeech.SUCCESS) return;

            byte[] buffer = new byte[samplesPerBuffer * Short.BYTES];
            boolean hasAudio = false;
            // shortcut: The computer endpoint takes only text, honor system rate and pitch when it supports them.
            for (int start = 0; start < text.length() && !cancelled.getAsBoolean();) {
                int end = segmentEnd(text, start);
                String segment = text.substring(start, end);
                start = end;
                if (segment.codePoints().allMatch(cp -> Character.isWhitespace(cp)
                        || Character.isSpaceChar(cp))) continue;
                short[] pcm = computer.fetch(servers, segment, cancelled);
                if (pcm == null || cancelled.getAsBoolean()) return;
                for (int offset = 0; offset < pcm.length && !cancelled.getAsBoolean();) {
                    int count = Math.min(samplesPerBuffer, pcm.length - offset);
                    for (int i = 0; i < count; i++) {
                        short sample = pcm[offset + i];
                        buffer[i * 2] = (byte) sample;
                        buffer[i * 2 + 1] = (byte) (sample >>> 8);
                    }
                    if (callback.audioAvailable(buffer, 0, count * Short.BYTES)
                            != TextToSpeech.SUCCESS) return;
                    offset += count;
                    hasAudio = true;
                }
            }
            if (!hasAudio && !cancelled.getAsBoolean()) callback.error(TextToSpeech.ERROR_INVALID_REQUEST);
        } catch (IOException e) {
            if (!cancelled.getAsBoolean()) callback.error(TextToSpeech.ERROR_NETWORK);
        } catch (JSONException e) {
            if (!cancelled.getAsBoolean()) callback.error(TextToSpeech.ERROR_SERVICE);
        } finally {
            callback.done();
        }
    }

    static int segmentEnd(String text, int start) {
        int end = start;
        int sentenceEnd = start;
        int wordEnd = start;
        for (int count = 1; count <= MAX_SEGMENT_CODE_POINTS && end < text.length(); count++) {
            int cp = text.codePointAt(end);
            end += Character.charCount(cp);
            if (count < MAX_SEGMENT_CODE_POINTS / 2) continue;
            if ("。！？；.!?;\n".indexOf(cp) >= 0) {
                sentenceEnd = end;
            } else if ("，、：,:".indexOf(cp) >= 0 || Character.isWhitespace(cp)) {
                wordEnd = end;
            }
        }
        if (end == text.length()) return end;
        if (sentenceEnd > start) return sentenceEnd;
        return wordEnd > start ? wordEnd : end;
    }

    public static final class VoiceDataActivity extends Activity {
        @Override
        protected void onCreate(Bundle state) {
            super.onCreate(state);
            String action = getIntent().getAction();
            Intent result = new Intent();
            if (TextToSpeech.Engine.ACTION_CHECK_TTS_DATA.equals(action)) {
                ArrayList<String> locales = new ArrayList<>();
                locales.add(LANGUAGE + "-" + COUNTRY);
                result.putStringArrayListExtra(TextToSpeech.Engine.EXTRA_AVAILABLE_VOICES, locales);
                setResult(TextToSpeech.Engine.CHECK_VOICE_DATA_PASS, result);
            } else if (TextToSpeech.Engine.ACTION_GET_SAMPLE_TEXT.equals(action)) {
                result.putExtra(TextToSpeech.Engine.EXTRA_SAMPLE_TEXT, getString(R.string.tts_system_sample));
                setResult(TextToSpeech.LANG_AVAILABLE, result);
            }
            finish();
        }
    }
}
