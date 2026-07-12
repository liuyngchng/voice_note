//
//  LlamaBridge.h
//  VoiceNote
//
//  ObjC bridge for llama.cpp C API — offline LLM inference
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LlamaBridge : NSObject

/// 加载 GGUF 模型文件
/// @param path GGUF 文件路径
/// @param gpuLayers GPU offload 层数 (0 = CPU only, 99 = 全部 GPU)
/// @param ctxLen 上下文长度 (建议 2048)
/// @param error 错误信息
/// @return 是否加载成功
- (BOOL)loadModel:(NSString *)path
       gpuLayers:(int)gpuLayers
   contextLength:(int)ctxLen
           error:(NSError **)error;

/// 根据 chat template 生成文本
/// @param prompt 用户 prompt
/// @param systemPrompt 系统提示 (可为 nil)
/// @param maxTokens 最大生成 token 数
/// @param temperature 温度 (0.0 ~ 1.0)
/// @param error 错误信息
/// @return 生成的文本
- (nullable NSString *)generateWithPrompt:(NSString *)prompt
                            systemPrompt:(nullable NSString *)systemPrompt
                               maxTokens:(int)maxTokens
                             temperature:(float)temperature
                                   error:(NSError **)error;

/// 卸载模型，释放内存
- (void)unloadModel;

/// 模型是否已加载
@property (nonatomic, readonly) BOOL isLoaded;

@end

NS_ASSUME_NONNULL_END
