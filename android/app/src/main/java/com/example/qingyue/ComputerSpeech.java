package com.example.qingyue;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class ComputerSpeech {
    static final int SAMPLE_RATE = 48000;
    private static final int HEADER_BYTES = 44;
    private static final int MAX_BYTES = 4 * 1024 * 1024;
    private static final int MAX_TEXT_CHARACTERS = 100;
    private static final int HEALTH_TIMEOUT_MS = 650;
    private static final int MAX_HEALTH_BYTES = 4096;
    private static final int SHORT_UTTERANCE_RETRY_FRAMES = SAMPLE_RATE * 4;
    private static final String ELLIPSIS_RUN = "(?:·{3,}+|…++|‥++|⋯{2,}+|[.．]{3,}+)";
    private static final Pattern ELLIPSIS_BEFORE_PUNCTUATION =
            Pattern.compile(ELLIPSIS_RUN + "(?=[\\s　]*[，。！？、；：,.!?;:…])");
    private static final Pattern ELLIPSIS_AT_SENTENCE_END =
            Pattern.compile(ELLIPSIS_RUN + "(?=[\\s　]*(?:[”’」』）】\"']|\\z))");
    private static final Pattern ELLIPSIS_PAUSE = Pattern.compile(ELLIPSIS_RUN);
    private static final String HAN = "[\u3400-\u4dbf\u4e00-\u9fff]";
    private static final Pattern SHORT_UTTERANCE_END = Pattern.compile(
            "\\A([\\s　“‘「『\"']*" + HAN + "{1,3})[!！?？.．:：]++(?=[\\s　”’」』\"']*\\z)");
    private static final Pattern SHORT_QUOTED_STATEMENT = Pattern.compile(
            "\\A[\\s　]*“[\\s　]*(" + HAN + "{1,12})。[\\s　]*”[\\s　]*\\z");
    private URI lastSuccessful;

    static boolean validText(String text) {
        return text != null && !text.trim().isEmpty()
                && text.codePointCount(0, text.length()) <= MAX_TEXT_CHARACTERS;
    }

    static List<URI> addresses(List<?> configured) {
        if (configured == null) return Collections.emptyList();
        List<URI> addresses = new ArrayList<>();
        for (Object value : configured) {
            if (!(value instanceof String)) continue;
            try {
                URI uri = new URI(((String) value).trim());
                String scheme = uri.getScheme();
                String path = uri.getRawPath();
                if (!("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme))
                        || uri.getHost() == null || uri.getPort() == 0 || uri.getPort() > 65535
                        || uri.getRawUserInfo() != null || uri.getRawQuery() != null
                        || uri.getRawFragment() != null || !(path.isEmpty() || "/".equals(path))) {
                    continue;
                }
                URI address = new URI(scheme.toLowerCase(Locale.ROOT), null, uri.getHost(),
                        uri.getPort(), null, null, null);
                if (!addresses.contains(address)) addresses.add(address);
            } catch (URISyntaxException invalid) {
                // Other configured addresses can still be used.
            }
        }
        return Collections.unmodifiableList(addresses);
    }

    short[] fetch(List<URI> addresses, String text, BooleanSupplier cancelled)
            throws IOException, JSONException {
        List<URI> candidates = new ArrayList<>(addresses);
        if (lastSuccessful != null && candidates.remove(lastSuccessful)) {
            candidates.add(0, lastSuccessful);
        }
        String spoken = synthesisText(text);
        byte[] body = synthesisBody(spoken);
        IOException lastFailure = null;
        for (URI address : candidates) {
            if (cancelled.getAsBoolean()) return null;
            try {
                checkHealth(address);
                if (cancelled.getAsBoolean()) return null;
                short[] pcm = synthesize(address, body);
                lastSuccessful = address;
                return retryShortUtterance(address, spoken, pcm, cancelled);
            } catch (IOException failure) {
                lastFailure = failure;
            }
        }
        throw new IOException("No configured computer speech server returned audio", lastFailure);
    }

    private static String synthesisText(String text) {
        // Ellipses can make the speech model generate a long noise tail.
        String spoken = ELLIPSIS_BEFORE_PUNCTUATION.matcher(text).replaceAll("");
        spoken = ELLIPSIS_AT_SENTENCE_END.matcher(spoken).replaceAll("。");
        return ELLIPSIS_PAUSE.matcher(spoken).replaceAll("，");
    }

    private static byte[] synthesisBody(String spoken) throws JSONException {
        return new JSONObject().put("text", spoken).toString().getBytes(StandardCharsets.UTF_8);
    }

    private static short[] retryShortUtterance(URI address, String spoken, short[] pcm,
                                               BooleanSupplier cancelled) {
        if (pcm.length <= SHORT_UTTERANCE_RETRY_FRAMES || cancelled.getAsBoolean()) return pcm;
        Matcher ending = SHORT_UTTERANCE_END.matcher(spoken);
        String retryText;
        if (ending.find()) {
            retryText = ending.replaceFirst("$1。");
        } else {
            Matcher quoted = SHORT_QUOTED_STATEMENT.matcher(spoken);
            if (!quoted.matches() || pcm.length <= SAMPLE_RATE * Math.max(5, quoted.group(1).length())) return pcm;
            retryText = spoken.replace("“", "").replace("”", "");
        }
        try {
            short[] retry = synthesize(address, synthesisBody(retryText));
            return retry.length < pcm.length ? retry : pcm;
        } catch (IOException | JSONException ignored) {
            return pcm;
        }
    }

    private static HttpURLConnection connect(URI address, String path, int connectTimeout,
                                              int readTimeout) throws IOException {
        HttpURLConnection connection = (HttpURLConnection)
                address.resolve(path).toURL().openConnection(Proxy.NO_PROXY);
        connection.setConnectTimeout(connectTimeout);
        connection.setReadTimeout(readTimeout);
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        return connection;
    }

    private static void checkHealth(URI address) throws IOException {
        HttpURLConnection connection = connect(address, "/health", HEALTH_TIMEOUT_MS,
                HEALTH_TIMEOUT_MS);
        try {
            int status = connection.getResponseCode();
            int length = connection.getContentLength();
            if (status != HttpURLConnection.HTTP_OK || length <= 0 || length > MAX_HEALTH_BYTES
                    || !"tts".equals(connection.getHeaderField("X-Qingyue-Service"))) {
                throw new IOException("Computer speech server is not ready");
            }
            byte[] body = new byte[length];
            try (DataInputStream response = new DataInputStream(connection.getInputStream())) {
                response.readFully(body);
            }
            JSONObject health = new JSONObject(new String(body, StandardCharsets.UTF_8));
            if (!Boolean.TRUE.equals(health.opt("ready")) || !(health.opt("provider") instanceof String)) {
                throw new IOException("Computer speech server is not ready");
            }
        } catch (JSONException invalid) {
            throw new IOException("Invalid computer speech health response", invalid);
        } finally {
            connection.disconnect();
        }
    }

    private static short[] synthesize(URI address, byte[] body) throws IOException {
        HttpURLConnection connection = connect(address, "/synthesize", 3000, 20000);
        try {
            connection.setRequestMethod("POST");
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setFixedLengthStreamingMode(body.length);
            connection.setDoOutput(true);
            try (OutputStream request = connection.getOutputStream()) {
                request.write(body);
            }
            int status = connection.getResponseCode();
            int length = connection.getContentLength();
            if (status != HttpURLConnection.HTTP_OK || !"audio/wav".equals(connection.getContentType())
                    || length <= HEADER_BYTES || length > MAX_BYTES) {
                throw new IOException("Unexpected computer speech response: HTTP " + status
                        + ", bytes=" + length);
            }
            byte[] wav = new byte[length];
            try (DataInputStream response = new DataInputStream(connection.getInputStream())) {
                response.readFully(wav);
            }
            return decode(wav);
        } finally {
            connection.disconnect();
        }
    }

    static short[] decode(byte[] wav) throws IOException {
        // shortcut: The server's WAV writer emits a fixed PCM header, use a chunk reader if it changes.
        ByteBuffer bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN);
        if (wav.length <= HEADER_BYTES || wav.length > MAX_BYTES || (wav.length & 1) != 0
                || bytes.getInt(0) != 0x46464952 || bytes.getInt(4) != wav.length - 8
                || bytes.getInt(8) != 0x45564157 || bytes.getInt(12) != 0x20746d66
                || bytes.getInt(16) != 16 || bytes.getShort(20) != 1 || bytes.getShort(22) != 1
                || bytes.getInt(24) != SAMPLE_RATE || bytes.getInt(28) != SAMPLE_RATE * Short.BYTES
                || bytes.getShort(32) != Short.BYTES || bytes.getShort(34) != 16
                || bytes.getInt(36) != 0x61746164 || bytes.getInt(40) != wav.length - HEADER_BYTES) {
            throw new IOException("Expected 48 kHz mono PCM16 WAV");
        }
        bytes.position(HEADER_BYTES);
        short[] pcm = new short[bytes.remaining() / Short.BYTES];
        bytes.asShortBuffer().get(pcm);
        return pcm;
    }
}
