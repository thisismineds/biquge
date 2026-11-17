# Sherpa's JNI accesses Kotlin classes, fields and callbacks by their exact names.
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keepclassmembers class com.example.qingyue.OfflineNarrator$SynthesisCancellation {
    java.lang.Integer invoke(float[]);
}
