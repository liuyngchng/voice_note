#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <android/log.h>

#include "sherpa-onnx/c-api/c-api.h"

#define TAG "SherpaOnnxJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Offline Recognizer (SenseVoice ASR) ─────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeCreateRecognizer(
    JNIEnv *env, jclass clazz, jstring modelPath, jstring tokensPath) {

    const char *c_model = (*env)->GetStringUTFChars(env, modelPath, NULL);
    const char *c_tokens = (*env)->GetStringUTFChars(env, tokensPath, NULL);

    if (!c_model || !c_tokens) {
        LOGE("Failed to get path strings");
        if (c_model) (*env)->ReleaseStringUTFChars(env, modelPath, c_model);
        return 0;
    }

    LOGI("Creating recognizer: model=%s, tokens=%s", c_model, c_tokens);

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.sense_voice.model = c_model;
    config.model_config.sense_voice.language = "auto";
    config.model_config.sense_voice.use_itn = 1;

    config.model_config.tokens = c_tokens;
    config.model_config.num_threads = 4;
    config.model_config.provider = "cpu";
    config.model_config.debug = 0;

    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *recognizer =
        SherpaOnnxCreateOfflineRecognizer(&config);

    (*env)->ReleaseStringUTFChars(env, modelPath, c_model);
    (*env)->ReleaseStringUTFChars(env, tokensPath, c_tokens);

    if (!recognizer) {
        LOGE("Failed to create recognizer");
        return 0;
    }

    LOGI("Recognizer created successfully");
    return (jlong)(intptr_t)recognizer;
}

JNIEXPORT jstring JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeRecognize(
    JNIEnv *env, jclass clazz, jlong recognizerPtr, jfloatArray samples) {

    if (recognizerPtr == 0) {
        LOGE("Null recognizer pointer");
        return NULL;
    }

    const SherpaOnnxOfflineRecognizer *recognizer =
        (const SherpaOnnxOfflineRecognizer *)(intptr_t)recognizerPtr;

    const SherpaOnnxOfflineStream *stream =
        SherpaOnnxCreateOfflineStream(recognizer);

    if (!stream) {
        LOGE("Failed to create offline stream");
        return NULL;
    }

    jsize n = (*env)->GetArrayLength(env, samples);
    jfloat *c_samples = (*env)->GetFloatArrayElements(env, samples, NULL);

    if (!c_samples) {
        LOGE("Failed to get sample array");
        SherpaOnnxDestroyOfflineStream(stream);
        return NULL;
    }

    SherpaOnnxAcceptWaveformOffline(stream, 16000, c_samples, n);
    SherpaOnnxDecodeOfflineStream(recognizer, stream);

    const SherpaOnnxOfflineRecognizerResult *result =
        SherpaOnnxGetOfflineStreamResult(stream);

    jstring j_text = NULL;
    if (result && result->text) {
        j_text = (*env)->NewStringUTF(env, result->text);
    }

    if (result) {
        SherpaOnnxDestroyOfflineRecognizerResult(result);
    }

    (*env)->ReleaseFloatArrayElements(env, samples, c_samples, JNI_ABORT);
    SherpaOnnxDestroyOfflineStream(stream);

    return j_text;
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeDestroyRecognizer(
    JNIEnv *env, jclass clazz, jlong recognizerPtr) {

    if (recognizerPtr == 0) return;

    const SherpaOnnxOfflineRecognizer *recognizer =
        (const SherpaOnnxOfflineRecognizer *)(intptr_t)recognizerPtr;

    SherpaOnnxDestroyOfflineRecognizer(recognizer);
    LOGI("Recognizer destroyed");
}

// ── Voice Activity Detector (Silero VAD) ────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeCreateVad(
    JNIEnv *env, jclass clazz, jstring modelPath) {

    const char *c_model = (*env)->GetStringUTFChars(env, modelPath, NULL);
    if (!c_model) {
        LOGE("VAD: Failed to get model path string");
        return 0;
    }

    LOGI("VAD: Creating detector, model=%s", c_model);

    SherpaOnnxVadModelConfig config;
    memset(&config, 0, sizeof(config));

    config.silero_vad.model = c_model;
    config.silero_vad.threshold = 0.5f;
    config.silero_vad.min_silence_duration = 0.5f;
    config.silero_vad.min_speech_duration = 0.25f;
    config.silero_vad.max_speech_duration = 30.0f;
    config.silero_vad.window_size = 512;

    config.sample_rate = 16000;
    config.num_threads = 1;
    config.provider = "cpu";

    const SherpaOnnxVoiceActivityDetector *vad =
        SherpaOnnxCreateVoiceActivityDetector(&config, 30.0f);

    (*env)->ReleaseStringUTFChars(env, modelPath, c_model);

    if (!vad) {
        LOGE("VAD: Failed to create voice activity detector");
        return 0;
    }

    LOGI("VAD: Detector created successfully");
    return (jlong)(intptr_t)vad;
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeDestroyVad(
    JNIEnv *env, jclass clazz, jlong vadPtr) {

    if (vadPtr == 0) return;

    const SherpaOnnxVoiceActivityDetector *vad =
        (const SherpaOnnxVoiceActivityDetector *)(intptr_t)vadPtr;

    SherpaOnnxDestroyVoiceActivityDetector(vad);
    LOGI("VAD: Detector destroyed");
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeVadAcceptWaveform(
    JNIEnv *env, jclass clazz, jlong vadPtr, jfloatArray samples, jint n) {

    if (vadPtr == 0) return;

    const SherpaOnnxVoiceActivityDetector *vad =
        (const SherpaOnnxVoiceActivityDetector *)(intptr_t)vadPtr;

    jfloat *c_samples = (*env)->GetFloatArrayElements(env, samples, NULL);
    if (!c_samples) {
        LOGE("VAD: Failed to get sample array");
        return;
    }

    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, c_samples, n);

    (*env)->ReleaseFloatArrayElements(env, samples, c_samples, JNI_ABORT);
}

JNIEXPORT jboolean JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeVadEmpty(
    JNIEnv *env, jclass clazz, jlong vadPtr) {

    if (vadPtr == 0) return JNI_TRUE;

    const SherpaOnnxVoiceActivityDetector *vad =
        (const SherpaOnnxVoiceActivityDetector *)(intptr_t)vadPtr;

    return SherpaOnnxVoiceActivityDetectorEmpty(vad) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jfloatArray JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeVadFront(
    JNIEnv *env, jclass clazz, jlong vadPtr) {

    if (vadPtr == 0) return NULL;

    const SherpaOnnxVoiceActivityDetector *vad =
        (const SherpaOnnxVoiceActivityDetector *)(intptr_t)vadPtr;

    const SherpaOnnxSpeechSegment *segment =
        SherpaOnnxVoiceActivityDetectorFront(vad);

    if (!segment || !segment->samples || segment->n <= 0) {
        if (segment) SherpaOnnxDestroySpeechSegment(segment);
        return NULL;
    }

    jfloatArray result = (*env)->NewFloatArray(env, segment->n);
    (*env)->SetFloatArrayRegion(env, result, 0, segment->n, segment->samples);

    SherpaOnnxDestroySpeechSegment(segment);
    return result;
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeVadPop(
    JNIEnv *env, jclass clazz, jlong vadPtr) {

    if (vadPtr == 0) return;

    const SherpaOnnxVoiceActivityDetector *vad =
        (const SherpaOnnxVoiceActivityDetector *)(intptr_t)vadPtr;

    SherpaOnnxVoiceActivityDetectorPop(vad);
}

JNIEXPORT jboolean JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeVadIsDetected(
    JNIEnv *env, jclass clazz, jlong vadPtr) {

    if (vadPtr == 0) return JNI_FALSE;

    const SherpaOnnxVoiceActivityDetector *vad =
        (const SherpaOnnxVoiceActivityDetector *)(intptr_t)vadPtr;

    return SherpaOnnxVoiceActivityDetectorDetected(vad) ? JNI_TRUE : JNI_FALSE;
}

// ── Offline Punctuation Restoration ────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeCreatePunctuation(
    JNIEnv *env, jclass clazz, jstring modelPath) {

    const char *c_model = (*env)->GetStringUTFChars(env, modelPath, NULL);
    if (!c_model) {
        LOGE("Punct: Failed to get model path string");
        return 0;
    }

    LOGI("Punct: Creating processor, model=%s", c_model);

    SherpaOnnxOfflinePunctuationConfig config;
    memset(&config, 0, sizeof(config));

    config.model.ct_transformer = c_model;
    config.model.num_threads = 1;
    config.model.provider = "cpu";
    config.model.debug = 0;

    const SherpaOnnxOfflinePunctuation *punct =
        SherpaOnnxCreateOfflinePunctuation(&config);

    (*env)->ReleaseStringUTFChars(env, modelPath, c_model);

    if (!punct) {
        LOGE("Punct: Failed to create processor");
        return 0;
    }

    LOGI("Punct: Processor created successfully");
    return (jlong)(intptr_t)punct;
}

JNIEXPORT jstring JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeAddPunctuation(
    JNIEnv *env, jclass clazz, jlong punctPtr, jstring text) {

    if (punctPtr == 0) {
        LOGE("Punct: Null processor pointer");
        return NULL;
    }

    const char *c_text = (*env)->GetStringUTFChars(env, text, NULL);
    if (!c_text) {
        LOGE("Punct: Failed to get text string");
        return NULL;
    }

    const SherpaOnnxOfflinePunctuation *punct =
        (const SherpaOnnxOfflinePunctuation *)(intptr_t)punctPtr;

    const char *c_result = SherpaOfflinePunctuationAddPunct(punct, c_text);

    jstring j_result = NULL;
    if (c_result) {
        j_result = (*env)->NewStringUTF(env, c_result);
        SherpaOfflinePunctuationFreeText(c_result);
    }

    (*env)->ReleaseStringUTFChars(env, text, c_text);

    // Fallback: return the original text object if punctuation produced nothing
    if (!j_result) {
        return text;
    }

    return j_result;
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_asr_OfflineASRClient_nativeDestroyPunctuation(
    JNIEnv *env, jclass clazz, jlong punctPtr) {

    if (punctPtr == 0) return;

    const SherpaOnnxOfflinePunctuation *punct =
        (const SherpaOnnxOfflinePunctuation *)(intptr_t)punctPtr;

    SherpaOnnxDestroyOfflinePunctuation(punct);
    LOGI("Punct: Processor destroyed");
}
