# Hilt
-keep class dagger.hilt.** { *; }
-keep class javax.inject.** { *; }

# Room
-keep class com.voicenote.app.core.database.** { *; }

# Gson
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.voicenote.app.domain.model.** { *; }

# sherpa-onnx JNI
-keep class com.voicenote.app.core.asr.OfflineASRClient {
    native <methods>;
}

# llama.cpp JNI
-keep class com.voicenote.app.core.llm.LlamaBridge {
    native <methods>;
    boolean isAvailable();
    boolean isLoaded();
}
