//
//  LlamaBridge.mm
//  VoiceNote
//
//  ObjC++ implementation wrapping llama.cpp C API for offline LLM inference
//

#import "LlamaBridge.h"

// llama.cpp C API — available via xcframework
#include <llama.h>
#include <ggml.h>

#include <vector>
#include <string>
#include <algorithm>

#import <os/log.h>

static NSString *const LlamaBridgeErrorDomain = @"LlamaBridgeErrorDomain";

@interface LlamaBridge () {
    llama_model *_model;
    llama_context *_ctx;
    const llama_vocab *_vocab;
    int _gpuLayers;
    int _ctxLen;
}
@property (nonatomic, readwrite) BOOL isLoaded;
@property (nonatomic) dispatch_queue_t inferenceQueue;
@end

@implementation LlamaBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _model = nullptr;
        _ctx = nullptr;
        _vocab = nullptr;
        _isLoaded = NO;
        _gpuLayers = 0;
        _ctxLen = 2048;
        _inferenceQueue = dispatch_queue_create("com.voicenote.llama-bridge", DISPATCH_QUEUE_SERIAL);

        // 记录 llama.cpp 初始化
        os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] llama.cpp backend initialized");
    }
    return self;
}

- (void)dealloc {
    [self unloadModel];
}

// MARK: - 加载模型

- (BOOL)loadModel:(NSString *)path
       gpuLayers:(int)gpuLayers
   contextLength:(int)ctxLen
           error:(NSError **)error {

    if (_isLoaded) {
        [self unloadModel];
    }

    const char *cPath = [path fileSystemRepresentation];
    if (!cPath) {
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"无效的模型路径"}];
        }
        return NO;
    }

    // 检查文件是否存在
    if (access(cPath, R_OK) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"模型文件不存在: %@", path]}];
        }
        return NO;
    }

    os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] 加载模型: %s, gpuLayers=%d, ctxLen=%d",
                cPath, gpuLayers, ctxLen);

    // 初始化 llama.cpp 后端
    llama_backend_init();

    // 模型参数
    llama_model_params modelParams = llama_model_default_params();
    modelParams.n_gpu_layers = gpuLayers;
    modelParams.use_mmap = true;

    // 加载模型
    _model = llama_load_model_from_file(cPath, modelParams);
    if (!_model) {
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @"加载模型失败，可能文件损坏或内存不足"}];
        }
        llama_backend_free();
        return NO;
    }

    // 获取词表
    _vocab = llama_model_get_vocab(_model);

    // 上下文参数
    llama_context_params ctxParams = llama_context_default_params();
    ctxParams.n_ctx = ctxLen;
    ctxParams.n_batch = 512;
    ctxParams.n_threads = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (ctxParams.n_threads < 1) ctxParams.n_threads = 1;
    ctxParams.n_threads_batch = ctxParams.n_threads;

    // 创建推理上下文
    _ctx = llama_new_context_with_model(_model, ctxParams);
    if (!_ctx) {
        llama_model_free(_model);
        _model = nullptr;
        llama_backend_free();
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @"创建推理上下文失败，尝试减小上下文长度"}];
        }
        return NO;
    }

    _gpuLayers = gpuLayers;
    _ctxLen = ctxLen;
    _isLoaded = YES;

    // 打印模型信息
    char descBuf[256] = {0};
    llama_model_desc(_model, descBuf, sizeof(descBuf));
    uint64_t nParams = llama_model_n_params(_model);
    os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] 模型就绪: %s, params=%lluM, ctx=%d, gpu=%d",
                descBuf, (unsigned long long)(nParams / 1'000'000), ctxLen, gpuLayers);

    return YES;
}

// MARK: - 文本生成

- (NSString *)generateWithPrompt:(NSString *)prompt
                    systemPrompt:(NSString *)systemPrompt
                       maxTokens:(int)maxTokens
                     temperature:(float)temperature
                           error:(NSError **)error {

    if (!_isLoaded || !_model || !_ctx || !_vocab) {
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-5
                                     userInfo:@{NSLocalizedDescriptionKey: @"模型未加载"}];
        }
        return nil;
    }

    // 根据是否有 system prompt 构造消息数组
    // 使用 llama.cpp 的 llama_chat_message 结构
    int nMsg = systemPrompt ? 2 : 1;
    std::vector<llama_chat_message> messages(nMsg);

    if (systemPrompt) {
        messages[0] = {"system", [systemPrompt UTF8String]};
        messages[1] = {"user", [prompt UTF8String]};
    } else {
        messages[0] = {"user", [prompt UTF8String]};
    }

    // 应用 chat template 格式化 prompt
    // Qwen/Qwen3 GGUF 文件自包含 chat template
    const char *tmpl = llama_model_chat_template(_model, nullptr);
    int estimatedLen = -(int)strlen(prompt.UTF8String) - 512;
    if (systemPrompt) {
        estimatedLen -= (int)strlen(systemPrompt.UTF8String);
    }

    std::vector<char> formatted(llama_n_ctx(_ctx) - estimatedLen > 0
                                ? llama_n_ctx(_ctx) - estimatedLen
                                : 4096);

    int newLen = llama_chat_apply_template(
        tmpl,
        messages.data(), nMsg,
        true,  // add_assistant (adds BOS token if needed)
        formatted.data(), (int)formatted.size()
    );

    if (newLen < 0) {
        // 缓冲区不够，重新分配
        formatted.resize(-newLen);
        newLen = llama_chat_apply_template(
            tmpl,
            messages.data(), nMsg,
            true,
            formatted.data(), (int)formatted.size()
        );
    }

    if (newLen < 0) {
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-6
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Chat template 应用失败: %d", newLen]}];
        }
        return nil;
    }

    std::string promptStr(formatted.data(), newLen);
    os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] Prompt 长度: %d chars (格式化后)", newLen);

    // Tokenize
    const int nCtx = llama_n_ctx(_ctx);
    std::vector<llama_token> tokens(std::max(512, nCtx));
    int nTokens = llama_tokenize(_vocab, promptStr.c_str(), (int)promptStr.size(),
                                 tokens.data(), (int)tokens.size(), true, true);

    if (nTokens < 0) {
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-7
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Tokenize 失败: %d", nTokens]}];
        }
        return nil;
    }
    tokens.resize(nTokens);

    // 检查上下文是否足够
    if (nTokens + maxTokens > nCtx) {
        maxTokens = nCtx - nTokens;
        if (maxTokens <= 0) {
            if (error) {
                *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                             code:-8
                                         userInfo:@{NSLocalizedDescriptionKey: @"提示文本超出上下文长度"}];
            }
            return nil;
        }
    }

    // 创建采样器
    // 使用新版 sampler chain API
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sparams.no_perf = true;

    llama_sampler *smpl = llama_sampler_chain_init(sparams);
    if (temperature <= 0.0f) {
        // greedy
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(42));
    }

    // 预填充: 一次性 decode 所有 prompt tokens
    llama_batch batch = llama_batch_get_one(tokens.data(), (int)tokens.size());
    if (llama_decode(_ctx, batch) != 0) {
        llama_sampler_free(smpl);
        if (error) {
            *error = [NSError errorWithDomain:LlamaBridgeErrorDomain
                                         code:-9
                                     userInfo:@{NSLocalizedDescriptionKey: @"推理预填充失败"}];
        }
        return nil;
    }

    // 自回归生成
    std::string result;
    result.reserve(maxTokens * 4); // UTF-8 预留空间

    llama_token eosToken = llama_vocab_eos(_vocab);
    llama_token eotToken = llama_vocab_eot(_vocab);

    for (int i = 0; i < maxTokens; i++) {
        // 采样下一个 token
        llama_token newToken = llama_sampler_sample(smpl, _ctx, -1);

        // 检查停止条件
        if (newToken == eosToken || newToken == eotToken) {
            break;
        }

        // Detokenize 并追加
        char buf[256];
        int nChars = llama_token_to_piece(_vocab, newToken, buf, sizeof(buf), 0, true);
        if (nChars > 0) {
            result.append(buf, nChars);
        }

        // 准备下一个 batch (single token)
        batch = llama_batch_get_one(&newToken, 1);
        if (llama_decode(_ctx, batch) != 0) {
            os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] decode 在第 %d 步失败", i);
            break;
        }
    }

    llama_sampler_free(smpl);

    // 清理上下文状态，保留 KV cache 供下次用？不，单次总结用完就清
    // 通过重新创建 context 来清理（简单可靠）

    os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] 生成完成: %zu chars (%zu tokens)",
                result.size(), result.size() > 0 ? tokens.size() : 0);

    return [NSString stringWithUTF8String:result.c_str()];
}

// MARK: - 卸载

- (void)unloadModel {
    dispatch_sync(_inferenceQueue, ^{
        if (_ctx) {
            llama_free(_ctx);
            _ctx = nullptr;
        }
        if (_model) {
            llama_model_free(_model);
            _model = nullptr;
        }
        _vocab = nullptr;
        _isLoaded = NO;
        llama_backend_free();
        os_log_info(OS_LOG_DEFAULT, "[LlamaBridge] 模型已卸载");
    });
}

@end
