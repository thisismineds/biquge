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
    private static final String OUTER_OPEN = "“‘「『\"'（(【[〔《〈｛{［〘〚〖«‹";
    private static final String OUTER_CLOSE = "”’」』\"'）)】]〕》〉｝}］〙〛〗»›";
    private static final String RISKY_PAUSE = "(?:·{3,}+|…++|‥++|⋯{2,}+|[.．]{3,}+|[!！?？]++|—{3,}+)++";
    private static final String SENTENCE_END = "(?=[\\s　]*(?:[”’」』）)】\\]〕》〉｝}］〙〛〗»›\"']|\\z))";
    private static final Pattern PAUSE_NEXT_TO_PUNCTUATION = Pattern.compile(
            "(?<=[，。；、,;:：])" + RISKY_PAUSE + "|" + RISKY_PAUSE + "(?=[\\s　]*[，。；、,.．;:：])");
    private static final Pattern PAUSE_AT_SENTENCE_END = Pattern.compile(RISKY_PAUSE + SENTENCE_END);
    private static final Pattern MID_SENTENCE_PAUSE = Pattern.compile(RISKY_PAUSE);
    private static final Pattern TERMINAL_DOT_OR_COLON = Pattern.compile("[.．:：]++" + SENTENCE_END);
    private static final int MIN_SHORT_LINE_RETRY_SECONDS = 4;
    private static final Pattern SHORT_LINE_WITH_STOP = Pattern.compile(
            "\\A([\\s　]*([\u3400-\u4dbf\u4e00-\u9fff]{1,12}))。(?=[\\s　]*\\z)");
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
                return retryWithoutTerminalStop(address, spoken, pcm, cancelled);
            } catch (IOException failure) {
                lastFailure = failure;
            }
        }
        throw new IOException("No configured computer speech server returned audio", lastFailure);
    }

    private static String synthesisText(String text) {
        // Preserve pauses while keeping unstable punctuation away from the speech model.
        String spoken = stripOuterWrappers(text);
        spoken = PAUSE_NEXT_TO_PUNCTUATION.matcher(spoken).replaceAll("");
        spoken = PAUSE_AT_SENTENCE_END.matcher(spoken).replaceAll("。");
        spoken = MID_SENTENCE_PAUSE.matcher(spoken).replaceAll("，");
        return TERMINAL_DOT_OR_COLON.matcher(spoken).replaceAll("。");
    }

    private static byte[] synthesisBody(String spoken) throws JSONException {
        return new JSONObject().put("text", spoken).toString().getBytes(StandardCharsets.UTF_8);
    }

    private static short[] retryWithoutTerminalStop(URI address, String spoken, short[] pcm,
                                                    BooleanSupplier cancelled) {
        if (pcm.length <= SAMPLE_RATE * MIN_SHORT_LINE_RETRY_SECONDS) return pcm;
        Matcher shortLine = SHORT_LINE_WITH_STOP.matcher(spoken);
        if (!shortLine.find()
                || pcm.length <= SAMPLE_RATE * Math.max(MIN_SHORT_LINE_RETRY_SECONDS, shortLine.group(2).length())
                || cancelled.getAsBoolean()) return pcm;
        try {
            short[] retry = synthesize(address, synthesisBody(shortLine.replaceFirst("$1")));
            return retry.length < pcm.length ? retry : pcm;
        } catch (IOException | JSONException ignored) {
            return pcm;
        }
    }

    private static String stripOuterWrappers(String text) {
        String spoken = text;
        while (true) {
            int first = 0;
            int last = spoken.length() - 1;
            while (first < last && isSpace(spoken.charAt(first))) first++;
            while (last > first && isSpace(spoken.charAt(last))) last--;
            if (first >= last) return spoken;
            char open = spoken.charAt(first);
            int pair = OUTER_OPEN.indexOf(open);
            if (pair < 0) return spoken;
            char close = OUTER_CLOSE.charAt(pair);
            if (spoken.charAt(last) != close || !enclosesText(spoken, first, last, open, close)) {
                return spoken;
            }
            spoken = spoken.substring(0, first) + spoken.substring(first + 1, last)
                    + spoken.substring(last + 1);
        }
    }

    private static boolean isSpace(char ch) {
        return Character.isWhitespace(ch) || Character.isSpaceChar(ch);
    }

    private static boolean enclosesText(String text, int first, int last, char open, char close) {
        int depth = 1;
        for (int index = first + 1; index < last; index++) {
            char ch = text.charAt(index);
            if (ch == open && open != close) {
                depth++;
            } else if (ch == close) {
                if ((ch == '\'' || ch == '’') && isAsciiWord(text.charAt(index - 1))
                        && isAsciiWord(text.charAt(index + 1))) continue;
                if (--depth == 0) return false;
            }
        }
        return depth == 1;
    }

    private static boolean isAsciiWord(char ch) {
        return ch < 128 && Character.isLetterOrDigit(ch);
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
