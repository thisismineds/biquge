package com.example.qingyue;

final class NarrationEqualizer {
    private NarrationEqualizer() {}

    static void apply(float[] samples, int sampleRate) {
        if (samples.length == 0 || sampleRate <= 0) return;
        // First-order high-pass to ease low rumble without thinning the voice.
        double maxCutoff = 0.4 * sampleRate;
        double k = Math.tan(Math.PI * Math.min(82.0, maxCutoff) / sampleRate);
        double highPassB = 1.0 / (1.0 + k);
        double highPassA = (k - 1.0) * highPassB;

        // Broad +2 dB presence bell (Q=0.9) centered at 2.5 kHz.
        double omega = 2.0 * Math.PI * Math.min(2500.0, maxCutoff) / sampleRate;
        double amplitude = Math.pow(10.0, 2.0 / 40.0);
        double alpha = Math.sin(omega) / (2.0 * 0.9);
        double denominator = 1.0 + alpha / amplitude;
        double b0 = (1.0 + alpha * amplitude) / denominator;
        double b1 = -2.0 * Math.cos(omega) / denominator;
        double b2 = (1.0 - alpha * amplitude) / denominator;
        double a2 = (1.0 - alpha / amplitude) / denominator;

        // Butterworth low-pass: a smooth rolloff around 8 kHz, above the presence band.
        double lowPassK = Math.tan(Math.PI * Math.min(8000.0, maxCutoff) / sampleRate);
        double squaredK = lowPassK * lowPassK;
        double damping = Math.sqrt(2.0) * lowPassK;
        double lowPassDenominator = 1.0 + damping + squaredK;
        double lowPassB0 = squaredK / lowPassDenominator;
        double lowPassA1 = 2.0 * (squaredK - 1.0) / lowPassDenominator;
        double lowPassA2 = (1.0 - damping + squaredK) / lowPassDenominator;

        int fadeSamples = Math.max(1, Math.min(sampleRate / 100, (samples.length - 1) / 2));
        double previousInput = 0, highPassed = 0, delay1 = 0, delay2 = 0;
        double lowPassDelay1 = 0, lowPassDelay2 = 0, peak = 0;
        for (int i = 0; i < samples.length; i++) {
            double input = Float.isFinite(samples[i]) ? samples[i] : 0.0;
            highPassed = highPassB * (input - previousInput) - highPassA * highPassed;
            previousInput = input;
            double presence = b0 * highPassed + delay1;
            delay1 = b1 * (highPassed - presence) + delay2;
            delay2 = b2 * highPassed - a2 * presence;
            double output = lowPassB0 * presence + lowPassDelay1;
            lowPassDelay1 = 2.0 * lowPassB0 * presence - lowPassA1 * output + lowPassDelay2;
            lowPassDelay2 = lowPassB0 * presence - lowPassA2 * output;

            int edgeDistance = Math.min(i, samples.length - 1 - i);
            if (edgeDistance < fadeSamples) {
                output *= 0.5 * (1.0 - Math.cos(Math.PI * edgeDistance / fadeSamples));
            }
            samples[i] = (float) Math.max(-Float.MAX_VALUE, Math.min(Float.MAX_VALUE, output));
            peak = Math.max(peak, Math.abs(samples[i]));
        }

        // Reserve headroom with one gain value so peaks don't get hard-clipped.
        if (peak > 0.96) {
            double gain = 0.96 / peak;
            for (int i = 0; i < samples.length; i++) samples[i] *= gain;
        }
    }
}
