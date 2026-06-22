#include <jni.h>
#include <android/log.h>

#define TAG "LlamaBridge-Stub"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

// Stub implementations — llama.cpp source not present
// Clone https://github.com/ggerganov/llama.cpp into app/src/main/cpp/llama.cpp/ to enable

JNIEXPORT jboolean JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_loadModel(
    JNIEnv *env, jclass clazz, jstring path, jint gpu_layers, jint ctx_len) {
    LOGI("Stub: loadModel called but llama.cpp not available");
    return JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_generate(
    JNIEnv *env, jclass clazz, jstring prompt, jstring system_prompt,
    jint max_tokens, jfloat temperature) {
    LOGI("Stub: generate called but llama.cpp not available");
    return NULL;
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_unloadModel(
    JNIEnv *env, jclass clazz) {
    LOGI("Stub: unloadModel called");
}

JNIEXPORT jboolean JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_isLoaded(
    JNIEnv *env, jclass clazz) {
    return JNI_FALSE;
}
