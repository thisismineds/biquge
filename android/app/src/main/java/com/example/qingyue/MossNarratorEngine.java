/*
 * Copyright 2026 OpenMOSS Team, Fudan University, SII and MOSI
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Adapted from OpenMOSS/MOSS-TTS-Nano's Android ONNX Runtime example
 * (31f42bae0a181849864c7ee39e8b88990909065f). Qingyue uses arbitrary text
 * and a pre-encoded synthetic reference, with cancellation between frames.
 */
package com.example.qingyue;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OnnxTensorLike;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtException;
import ai.onnxruntime.OrtSession;
import ai.onnxruntime.extensions.OrtxPackage;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.LongBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.function.BooleanSupplier;

/** Owns the model sessions. Used exclusively by the offline narrator's worker. */
final class MossNarratorEngine implements AutoCloseable {
    private static final int SAMPLE_RATE = 48000;
    // Decoding a whole utterance makes the vocoder's native working memory grow with its length.
    private static final int CODEC_BATCH_FRAMES = 16;
    private static final float[] NO_AUDIO = new float[0];

    private final OrtEnvironment environment = OrtEnvironment.getEnvironment();
    private final List<OrtSession> sessions = new ArrayList<>(5);
    private final OrtSession.SessionOptions options;
    private final OrtSession tokenizer;
    private final OrtSession prefill;
    private final OrtSession decode;
    private final OrtSession sampler;
    private final OrtSession vocoder;
    private final int quantizers;
    private final int codebookSize;
    private final int audioPad;
    private final int audioStart;
    private final int audioEnd;
    private final int userAudio;
    private final int assistantAudio;
    private final int maxFrames;
    private final int[] prefix;
    private final int[] suffix;
    private final int[] assistantPrefix;
    private final int[][] voice;
    private final String[] cacheInputs;
    private final String[] cacheOutputs;
    private final int samplesPerFrame;
    private final List<CodecState> codecStates = new ArrayList<>();

    private static final class CodecState {
        final String input;
        final String output;
        final long[] shape;
        final int size;
        final boolean floatingPoint;
        final int initialValue;

        CodecState(String input, String output, JSONArray dimensions, boolean floatingPoint,
                   int initialValue) throws JSONException {
            this.input = input;
            this.output = output;
            this.floatingPoint = floatingPoint;
            this.initialValue = initialValue;
            shape = new long[dimensions.length()];
            int elements = 1;
            for (int i = 0; i < shape.length; i++) {
                int dimension = dimensions.getInt(i);
                if (dimension <= 0) throw new JSONException("Invalid MOSS codec state dimension");
                shape[i] = dimension;
                elements = Math.multiplyExact(elements, dimension);
            }
            size = elements;
        }
    }

    MossNarratorEngine(File modelDir) throws IOException, JSONException, OrtException {
        JSONObject manifest = new JSONObject(readText(modelDir, "browser_poc_manifest.json"));
        JSONObject model = manifest.getJSONObject("tts_config");
        quantizers = model.getInt("n_vq");
        codebookSize = model.getJSONArray("audio_codebook_sizes").getInt(0);
        audioPad = model.getInt("audio_pad_token_id");
        audioStart = model.getInt("audio_start_token_id");
        audioEnd = model.getInt("audio_end_token_id");
        userAudio = model.getInt("audio_user_slot_token_id");
        assistantAudio = model.getInt("audio_assistant_slot_token_id");
        maxFrames = manifest.getJSONObject("generation_defaults").getInt("max_new_frames");
        JSONObject prompt = manifest.getJSONObject("prompt_templates");
        prefix = integers(prompt.getJSONArray("user_prompt_prefix_token_ids"));
        suffix = integers(prompt.getJSONArray("user_prompt_after_reference_token_ids"));
        assistantPrefix = integers(prompt.getJSONArray("assistant_prompt_prefix_token_ids"));
        JSONArray codes = new JSONArray(readText(modelDir, "qwen-reference-rvq.json"));
        if (codes.length() == 0) throw new IOException("Missing broadcast reference audio");
        voice = new int[codes.length()][];
        for (int i = 0; i < voice.length; i++) {
            voice[i] = integers(codes.getJSONArray(i));
            if (voice[i].length != quantizers) throw new IOException("Invalid voice code width");
        }
        JSONObject onnx = new JSONObject(readText(modelDir, "tts_browser_onnx_meta.json"))
                .getJSONObject("onnx");
        cacheInputs = namesFrom(onnx.getJSONArray("decode_input_names"), 2);
        cacheOutputs = namesFrom(onnx.getJSONArray("decode_output_names"), 1);
        if (cacheInputs.length != cacheOutputs.length) {
            throw new IOException("Inconsistent MOSS decode model metadata");
        }

        JSONObject codec = new JSONObject(readText(modelDir, "codec_browser_onnx_meta.json"));
        JSONObject codecConfig = codec.getJSONObject("codec_config");
        samplesPerFrame = codecConfig.getInt("downsample_rate");
        if (samplesPerFrame <= 0 || codecConfig.getInt("num_quantizers") != quantizers
                || codecConfig.getInt("sample_rate") != SAMPLE_RATE) {
            throw new IOException("Inconsistent MOSS codec model metadata");
        }
        JSONObject stream = codec.getJSONObject("streaming_decode");
        JSONArray transformers = stream.getJSONArray("transformer_offsets");
        for (int i = 0; i < transformers.length(); i++) {
            JSONObject state = transformers.getJSONObject(i);
            codecStates.add(new CodecState(state.getString("input_name"),
                    state.getString("output_name"), state.getJSONArray("shape"), false, 0));
        }
        JSONArray attention = stream.getJSONArray("attention_caches");
        for (int i = 0; i < attention.length(); i++) {
            JSONObject state = attention.getJSONObject(i);
            addCodecState(state, "offset", "offset_shape", false, 0);
            addCodecState(state, "cached_keys", "cache_shape", true, 0);
            addCodecState(state, "cached_values", "cache_shape", true, 0);
            addCodecState(state, "cached_positions", "positions_shape", false, -1);
        }

        options = new OrtSession.SessionOptions();
        try {
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
            options.setIntraOpNumThreads(2);
            options.setInterOpNumThreads(1);
            prefill = open(modelDir, "moss_tts_prefill.onnx", options);
            decode = open(modelDir, "moss_tts_decode_step.onnx", options);
            sampler = open(modelDir, "moss_tts_local_fixed_sampled_frame.onnx", options);
            vocoder = open(modelDir, "moss_audio_tokenizer_decode_step.onnx", options);
            options.registerCustomOpLibrary(OrtxPackage.getLibraryPath());
            tokenizer = open(modelDir, "tokenizer.onnx", options);
        } catch (IOException | OrtException | RuntimeException | LinkageError failure) {
            try {
                close();
            } catch (IllegalStateException cleanup) {
                failure.addSuppressed(cleanup);
            }
            throw failure;
        }
    }

    int sampleRate() {
        return SAMPLE_RATE;
    }

    float[] synthesize(String text, BooleanSupplier cancelled) throws OrtException {
        if (text.trim().isEmpty() || cancelled.getAsBoolean()) return NO_AUDIO;
        int[] tokens;
        try (OnnxTensor input = OnnxTensor.createTensor(environment, new String[]{text},
                     new long[]{1});
             OrtSession.Result result = tokenizer.run(Collections.singletonMap("text", input))) {
            tokens = intValues(tensor(result, "tokens"));
        }
        if (tokens.length == 0 || cancelled.getAsBoolean()) return NO_AUDIO;

        int width = quantizers + 1;
        int rows = prefix.length + voice.length + suffix.length + tokens.length
                + assistantPrefix.length + 3;
        int[] prompt = new int[rows * width];
        Arrays.fill(prompt, audioPad);
        int position = 0;
        for (int token : prefix) prompt[position++ * width] = token;
        prompt[position++ * width] = audioStart;
        for (int[] frame : voice) {
            int offset = position++ * width;
            prompt[offset] = userAudio;
            System.arraycopy(frame, 0, prompt, offset + 1, quantizers);
        }
        prompt[position++ * width] = audioEnd;
        for (int token : suffix) prompt[position++ * width] = token;
        for (int token : tokens) prompt[position++ * width] = token;
        for (int token : assistantPrefix) prompt[position++ * width] = token;
        prompt[position * width] = audioStart;
        int[] mask = new int[rows];
        Arrays.fill(mask, 1);
        OrtSession.Result initial;
        try (OnnxTensor ids = intTensor(IntBuffer.wrap(prompt), 1, rows, width);
             OnnxTensor attention = intTensor(IntBuffer.wrap(mask), 1, rows)) {
            Map<String, OnnxTensorLike> inputs = new HashMap<>();
            inputs.put("input_ids", ids);
            inputs.put("attention_mask", attention);
            initial = prefill.run(inputs);
        }
        int[] frames = new int[maxFrames * quantizers];
        int count = generateFrames(initial, rows, frames, cancelled);
        return count == 0 || cancelled.getAsBoolean() ? NO_AUDIO
                : decodeAudio(frames, count, cancelled);
    }

    private int generateFrames(OrtSession.Result initial, int rows, int[] frames,
                               BooleanSupplier cancelled) throws OrtException {
        OrtSession.Result cache = initial;
        try {
            IntBuffer seen = allocateInts(quantizers * codebookSize);
            IntBuffer row = allocateInts(quantizers + 1);
            IntBuffer validLength = allocateInts(1);
            FloatBuffer textRandom = allocateFloats(1);
            FloatBuffer audioRandom = allocateFloats(quantizers);
            row.put(0, assistantAudio);
            Random random = new Random(1234);
            try (OnnxTensor seenInput = intTensor(seen, 1, quantizers, codebookSize);
                 OnnxTensor rowInput = intTensor(row, 1, 1, quantizers + 1);
                 OnnxTensor lengthInput = intTensor(validLength, 1);
                 OnnxTensor textDraw = OnnxTensor.createTensor(environment, textRandom,
                         new long[]{1});
                 OnnxTensor audioDraw = OnnxTensor.createTensor(environment, audioRandom,
                         new long[]{1, quantizers})) {
                Map<String, OnnxTensorLike> sampleInputs = new HashMap<>();
                sampleInputs.put("repetition_seen_mask", seenInput);
                sampleInputs.put("assistant_random_u", textDraw);
                sampleInputs.put("audio_random_u", audioDraw);
                Map<String, OnnxTensorLike> decodeInputs = new HashMap<>();
                decodeInputs.put("input_ids", rowInput);
                decodeInputs.put("past_valid_lengths", lengthInput);
                for (int index = 0; index < maxFrames; index++) {
                    if (cancelled.getAsBoolean()) return 0;
                    textRandom.put(0, draw(random));
                    for (int channel = 0; channel < quantizers; channel++) {
                        audioRandom.put(channel, draw(random));
                    }
                    int[] frame;
                    try (OnnxTensor hidden = lastHidden(tensor(cache, "global_hidden"))) {
                        sampleInputs.put("global_hidden", hidden);
                        try (OrtSession.Result result = sampler.run(sampleInputs)) {
                            if (intValues(tensor(result, "should_continue"))[0] == 0) return index;
                            frame = intValues(tensor(result, "frame_token_ids"));
                        }
                    }
                    if (frame.length != quantizers) {
                        throw new IllegalStateException("Unexpected MOSS audio code count");
                    }
                    System.arraycopy(frame, 0, frames, index * quantizers, quantizers);
                    for (int channel = 0; channel < quantizers; channel++) {
                        int token = frame[channel];
                        if (token >= 0 && token < codebookSize) {
                            seen.put(channel * codebookSize + token, 1);
                        }
                        row.put(channel + 1, token);
                    }
                    validLength.put(0, rows + index);
                    for (int i = 0; i < cacheInputs.length; i++) {
                        decodeInputs.put(cacheInputs[i], tensor(cache, cacheOutputs[i]));
                    }
                    OrtSession.Result next = decode.run(decodeInputs);
                    cache.close();
                    cache = next;
                }
            }
            throw new IllegalStateException("MOSS narration exceeded its frame limit");
        } finally {
            cache.close();
        }
    }

    private float[] decodeAudio(int[] frames, int count, BooleanSupplier cancelled)
            throws OrtException {
        float[] mono = new float[Math.multiplyExact(count, samplesPerFrame)];
        List<OnnxTensor> initialStates = new ArrayList<>(codecStates.size());
        OrtSession.Result state = null;
        Map<String, OnnxTensorLike> inputs = new HashMap<>();
        try {
            for (CodecState spec : codecStates) {
                OnnxTensor input;
                if (spec.floatingPoint) {
                    input = OnnxTensor.createTensor(environment, allocateFloats(spec.size),
                            spec.shape);
                } else {
                    IntBuffer values = allocateInts(spec.size);
                    for (int i = 0; i < spec.size; i++) values.put(i, spec.initialValue);
                    input = intTensor(values, spec.shape);
                }
                initialStates.add(input);
                inputs.put(spec.input, input);
            }
            int written = 0;
            for (int start = 0; start < count; start += CODEC_BATCH_FRAMES) {
                if (cancelled.getAsBoolean()) return NO_AUDIO;
                int batch = Math.min(CODEC_BATCH_FRAMES, count - start);
                OrtSession.Result next;
                try (OnnxTensor codes = intTensor(
                             IntBuffer.wrap(frames, start * quantizers, batch * quantizers),
                             1, batch, quantizers);
                     OnnxTensor lengths = intTensor(IntBuffer.wrap(new int[]{batch}), 1)) {
                    inputs.put("audio_codes", codes);
                    inputs.put("audio_code_lengths", lengths);
                    next = vocoder.run(inputs);
                }
                OrtSession.Result previous = state;
                state = next;
                if (previous != null) previous.close();
                for (OnnxTensor seed : initialStates) seed.close();
                initialStates.clear();
                for (CodecState spec : codecStates) {
                    inputs.put(spec.input, tensor(state, spec.output));
                }
                int length = intValues(tensor(state, "audio_lengths"))[0];
                float[][] channels = ((float[][][]) tensor(state, "audio").getValue())[0];
                if (channels.length == 0 || length <= 0 || length > batch * samplesPerFrame
                        || length > mono.length - written) {
                    throw new IllegalStateException("Unexpected MOSS codec audio length");
                }
                for (float[] channel : channels) {
                    if (channel.length < length) {
                        throw new IllegalStateException("Incomplete MOSS codec audio");
                    }
                    for (int i = 0; i < length; i++) mono[written + i] += channel[i];
                }
                for (int i = 0; i < length; i++) mono[written + i] /= channels.length;
                written += length;
            }
            if (cancelled.getAsBoolean()) return NO_AUDIO;
            return written == mono.length ? mono : Arrays.copyOf(mono, written);
        } finally {
            if (state != null) state.close();
            for (OnnxTensor seed : initialStates) seed.close();
        }
    }

    private void addCodecState(JSONObject state, String name, String shape, boolean floatingPoint,
                               int initialValue) throws JSONException {
        codecStates.add(new CodecState(state.getString(name + "_input_name"),
                state.getString(name + "_output_name"), state.getJSONArray(shape),
                floatingPoint, initialValue));
    }

    private OnnxTensor lastHidden(OnnxTensor source) throws OrtException {
        long[] shape = source.getInfo().getShape();
        int width = (int) shape[shape.length - 1];
        FloatBuffer data = source.getFloatBuffer();
        data.position(data.limit() - width);
        return OnnxTensor.createTensor(environment, data, new long[]{1, width});
    }

    private OnnxTensor intTensor(IntBuffer buffer, long... shape) throws OrtException {
        return OnnxTensor.createTensor(environment, buffer, shape);
    }

    private OrtSession open(File directory, String name, OrtSession.SessionOptions options)
            throws IOException, OrtException {
        File file = new File(directory, name);
        if (!file.isFile()) throw new IOException("Missing MOSS model: " + name);
        OrtSession session = environment.createSession(file.getAbsolutePath(), options);
        sessions.add(session);
        return session;
    }

    @Override
    public void close() {
        IllegalStateException failure = null;
        for (OrtSession session : sessions) {
            try {
                session.close();
            } catch (OrtException exception) {
                if (failure == null) failure = new IllegalStateException("Closing MOSS sessions");
                failure.addSuppressed(exception);
            }
        }
        sessions.clear();
        options.close();
        if (failure != null) throw failure;
    }

    private static OnnxTensor tensor(OrtSession.Result result, String name) {
        return (OnnxTensor) result.get(name)
                .orElseThrow(() -> new IllegalStateException("Missing MOSS tensor: " + name));
    }

    private static int[] intValues(OnnxTensor tensor) {
        IntBuffer ints = tensor.getIntBuffer();
        if (ints != null) {
            int[] values = new int[ints.remaining()];
            ints.get(values);
            return values;
        }
        LongBuffer longs = tensor.getLongBuffer();
        if (longs == null) throw new IllegalStateException("Unexpected MOSS integer tensor type");
        int[] values = new int[longs.remaining()];
        for (int i = 0; i < values.length; i++) values[i] = Math.toIntExact(longs.get());
        return values;
    }

    private static String readText(File directory, String name) throws IOException {
        try (FileInputStream input = new FileInputStream(new File(directory, name));
             ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) bytes.write(buffer, 0, count);
            return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static int[] integers(JSONArray source) throws JSONException {
        int[] result = new int[source.length()];
        for (int i = 0; i < result.length; i++) result[i] = source.getInt(i);
        return result;
    }

    private static String[] namesFrom(JSONArray source, int start) throws JSONException {
        String[] result = new String[source.length() - start];
        for (int i = 0; i < result.length; i++) result[i] = source.getString(start + i);
        return result;
    }

    private static IntBuffer allocateInts(int size) {
        return ByteBuffer.allocateDirect(size * Integer.BYTES).order(ByteOrder.nativeOrder())
                .asIntBuffer();
    }

    private static FloatBuffer allocateFloats(int size) {
        return ByteBuffer.allocateDirect(size * Float.BYTES).order(ByteOrder.nativeOrder())
                .asFloatBuffer();
    }

    private static float draw(Random random) {
        return Math.max(0.000001f, Math.min(0.999999f, random.nextFloat()));
    }
}
