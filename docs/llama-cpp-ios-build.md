# llama.cpp XCFramework 构建与修复指南

## 源码位置

```
/Users/richard/workspace/llama.cpp
```

VoiceNote 项目使用该源码编译的 `llama.xcframework`，位于：

```
ios/VoiceNote/Libraries/llama.xcframework
```

## 构建脚本

项目内保存了构建脚本：`scripts/build-llama-ios.sh`

该脚本源自 `llama.cpp/build-ios-only.sh`（已在项目中修复并保存副本）。

### 构建步骤

```bash
cd /Users/richard/workspace/llama.cpp
./build-ios-only.sh
```

构建产物在 `build-apple/llama.xcframework`。

### 替换到项目

```bash
rm -rf /Users/richard/workspace/voice_note/ios/VoiceNote/Libraries/llama.xcframework
cp -R /Users/richard/workspace/llama.cpp/build-apple/llama.xcframework \
      /Users/richard/workspace/voice_note/ios/VoiceNote/Libraries/
rm -rf /Users/richard/workspace/voice_note/ios/build   # 清理 Xcode 缓存
```

### 构建脚本注意事项

需要 `LLAMA_BUILD_*=OFF` 关闭不需要的 example/tool，否则 CMake configure 报错：

```
-DLLAMA_BUILD_APP=OFF
-DLLAMA_BUILD_COMMON=OFF
-DLLAMA_BUILD_EXAMPLES=OFF
-DLLAMA_BUILD_TOOLS=OFF
-DLLAMA_BUILD_TESTS=OFF
-DLLAMA_BUILD_SERVER=OFF
```

## Metal Buffer 4096 对齐修复

### 问题

Metal debug layer 报错：

```
-[MTLDebugDevice newBufferWithBytesNoCopy:length:options:deallocator:]: 
failed assertion 'Buffer Validation
newBufferWithBytesNoCopy:length 0x94600 is not 4096 byte aligned.'
```

**根因**：ggml Metal backend 内部调用 `newBufferWithBytesNoCopy` 时，
`length` 参数传入的是实际数据大小，未向上取整到 4096（page size）的倍数。

### 修复位置（共 3 处）

#### 1. `ggml/src/ggml-metal/ggml-metal-device.m` — `ggml_metal_buffer_set_tensor`

```objc
// 在 newBufferWithBytesNoCopy 前加上：
const size_t page_size = sysconf(_SC_PAGESIZE);
const size_t size_aligned = (size + page_size - 1) & ~(page_size - 1);
// length: 改为 size_aligned
```

#### 2. `ggml/src/ggml-metal/ggml-metal-device.m` — `ggml_metal_buffer_get_tensor`

```objc
// 同上，length: 改为 size_aligned
```

#### 3. `ggml/src/ggml-metal/ggml-metal-context.m` — `ggml_metal_get_tensor_async`

```objc
// 同上，length: 改为 size_aligned
```

### 为什么向上取整是安全的

`newBufferWithBytesNoCopy` 的 `length` 只是告诉 Metal buffer 的"最大有效范围"。
实际的 blit 操作使用原始 `size` 作为 `copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:` 的参数，
Metal 不会访问超出 blit 范围的地址，所以长度多几个字节无害。

### 不需要在 app 侧补齐模型文件

`ggml_metal_buffer_map` 内部已经处理了 mmap buffer 的页对齐（指针前移覆盖未对齐头、size 后扩覆盖尾）。
**不要**在 app 侧对 GGUF 文件做 padding，那是无效的且会浪费磁盘空间。

### 注意

- 这个修复针对的是 **compute buffer**（推理过程中的临时 buffer）
- **不是**模型文件的 mmap buffer（那个 `ggml_metal_buffer_map` 已经自处理了）
- 在 Release 构建中 Metal 不开启 debug validation，可能不会触发此错误
- 但在 Debug 构建中 `MTLDebugDevice` 会严格校验
