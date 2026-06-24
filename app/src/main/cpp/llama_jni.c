#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

// llama.cpp C API — available via linked static library
#include "llama.h"
#include "ggml.h"

#define TAG "LlamaBridge-JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static struct llama_model *g_model = NULL;
static struct llama_context *g_ctx = NULL;
static const struct llama_vocab *g_vocab = NULL;
static int g_is_loaded = 0;

JNIEXPORT jboolean JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_loadModel(
    JNIEnv *env, jclass clazz, jstring path, jint gpu_layers, jint ctx_len) {

    if (g_is_loaded) {
        // unload existing model first
        if (g_ctx) { llama_free(g_ctx); g_ctx = NULL; }
        if (g_model) { llama_model_free(g_model); g_model = NULL; }
        g_vocab = NULL;
        g_is_loaded = 0;
        llama_backend_free();
    }

    const char *c_path = (*env)->GetStringUTFChars(env, path, NULL);
    if (!c_path) return JNI_FALSE;

    LOGI("Loading model: %s, gpuLayers=%d, ctxLen=%d", c_path, gpu_layers, ctx_len);

    llama_backend_init();

    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = gpu_layers;
    model_params.use_mmap = true;

    g_model = llama_model_load_from_file(c_path, model_params);
    (*env)->ReleaseStringUTFChars(env, path, c_path);

    if (!g_model) {
        LOGE("Failed to load model");
        llama_backend_free();
        return JNI_FALSE;
    }

    g_vocab = llama_model_get_vocab(g_model);

    struct llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = ctx_len;
    ctx_params.n_batch = 512;
    ctx_params.n_threads = 4;
    ctx_params.n_threads_batch = 4;

    g_ctx = llama_init_from_model(g_model, ctx_params);
    if (!g_ctx) {
        LOGE("Failed to create context");
        llama_model_free(g_model);
        g_model = NULL;
        llama_backend_free();
        return JNI_FALSE;
    }

    g_is_loaded = 1;
    LOGI("Model loaded successfully");
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_generate(
    JNIEnv *env, jclass clazz, jstring prompt, jstring system_prompt,
    jint max_tokens, jfloat temperature) {

    if (!g_is_loaded || !g_model || !g_ctx || !g_vocab) {
        LOGE("Model not loaded");
        return NULL;
    }

    const char *c_prompt = (*env)->GetStringUTFChars(env, prompt, NULL);
    const char *c_system = system_prompt ? (*env)->GetStringUTFChars(env, system_prompt, NULL) : NULL;

    // Build chat messages
    int n_msg = c_system ? 2 : 1;
    struct llama_chat_message messages[2];
    if (c_system) {
        messages[0] = (struct llama_chat_message){"system", c_system};
        messages[1] = (struct llama_chat_message){"user", c_prompt};
    } else {
        messages[0] = (struct llama_chat_message){"user", c_prompt};
    }

    // Apply chat template
    const char *tmpl = llama_model_chat_template(g_model, NULL);
    int estimated_len = -(int)strlen(c_prompt) - 512;
    if (c_system) estimated_len -= (int)strlen(c_system);

    int buf_size = llama_n_ctx(g_ctx) - estimated_len;
    if (buf_size <= 0) buf_size = 4096;

    char *formatted = malloc(buf_size);
    int new_len = llama_chat_apply_template(tmpl, messages, n_msg, 1,
                                            formatted, buf_size);
    if (new_len < 0) {
        free(formatted);
        formatted = malloc(-new_len);
        new_len = llama_chat_apply_template(tmpl, messages, n_msg, 1,
                                            formatted, -new_len);
    }

    (*env)->ReleaseStringUTFChars(env, prompt, c_prompt);
    if (c_system) (*env)->ReleaseStringUTFChars(env, system_prompt, c_system);

    if (new_len < 0) {
        LOGE("Chat template failed: %d", new_len);
        free(formatted);
        return NULL;
    }

    // Tokenize
    int n_ctx = llama_n_ctx(g_ctx);
    llama_token *tokens = malloc(sizeof(llama_token) * (n_ctx > 512 ? n_ctx : 512));
    int n_tokens = llama_tokenize(g_vocab, formatted, new_len, tokens,
                                  n_ctx > 512 ? n_ctx : 512, 1, 1);
    free(formatted);

    if (n_tokens < 0) {
        LOGE("Tokenize failed: %d", n_tokens);
        free(tokens);
        return NULL;
    }

    if (n_tokens + max_tokens > n_ctx) {
        max_tokens = n_ctx - n_tokens;
        if (max_tokens <= 0) {
            LOGE("Prompt exceeds context length");
            free(tokens);
            return NULL;
        }
    }

    // Sampler
    struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sparams.no_perf = true;
    struct llama_sampler *smpl = llama_sampler_chain_init(sparams);
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(42));
    }

    // Prefill
    llama_batch batch = llama_batch_get_one(tokens, n_tokens);
    if (llama_decode(g_ctx, batch) != 0) {
        LOGE("Prefill decode failed");
        llama_sampler_free(smpl);
        free(tokens);
        return NULL;
    }
    free(tokens);

    // Autoregressive generation
    char *result = malloc(max_tokens * 4 + 1);
    int result_len = 0;
    llama_token eos_token = llama_vocab_eos(g_vocab);
    llama_token eot_token = llama_vocab_eot(g_vocab);

    for (int i = 0; i < max_tokens; i++) {
        llama_token new_token = llama_sampler_sample(smpl, g_ctx, -1);
        if (new_token == eos_token || new_token == eot_token) break;

        char buf[256];
        int n_chars = llama_token_to_piece(g_vocab, new_token, buf, sizeof(buf), 0, 1);
        if (n_chars > 0 && result_len + n_chars < max_tokens * 4) {
            memcpy(result + result_len, buf, n_chars);
            result_len += n_chars;
        }

        batch = llama_batch_get_one(&new_token, 1);
        if (llama_decode(g_ctx, batch) != 0) {
            LOGI("Decode failed at step %d", i);
            break;
        }
    }
    result[result_len] = '\0';

    llama_sampler_free(smpl);
    LOGI("Generation complete: %d chars", result_len);

    jstring j_result = (*env)->NewStringUTF(env, result);
    free(result);
    return j_result;
}

JNIEXPORT void JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_unloadModel(
    JNIEnv *env, jclass clazz) {
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = NULL;
    }
    if (g_model) {
        llama_model_free(g_model);
        g_model = NULL;
    }
    g_vocab = NULL;
    g_is_loaded = 0;
    llama_backend_free();
    LOGI("Model unloaded");
}

JNIEXPORT jboolean JNICALL
Java_com_voicenote_app_core_llm_LlamaBridge_isLoaded(
    JNIEnv *env, jclass clazz) {
    return g_is_loaded ? JNI_TRUE : JNI_FALSE;
}
