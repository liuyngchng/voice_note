# iOS 版语音笔记

iOS 原生语音笔记 App —— 支持在线/离线语音转写与 AI 总结。

## 与 Android 版的对应关系

| Android | iOS |
|---|---|
| Kotlin | Swift |
| Jetpack Compose | SwiftUI |
| MVVM + Clean Architecture | MVVM + Clean Architecture |
| Hilt | 手动 DI（AppContainer） |
| Room + DataStore | Core Data + UserDefaults |
| OkHttp (REST + WebSocket) | URLSession (REST + WebSocket) |
| AudioRecord 16kHz/16bit/PCM | AVAudioEngine 16kHz/16bit/PCM |
| Foreground Service + WakeLock | Background Modes (audio) + AVAudioSession |
| LocationManager | —（未接入） |
| FunASR WebSocket 实时流式 | FunASR WebSocket 实时流式（在线模式） |
| —待实现 | Sherpa-ONNX + SenseVoice 离线识别 |
| —待实现 | llama.cpp + Qwen2.5 GGUF 离线 LLM 总结 |
| OpenAI 兼容 LLM 接口 | OpenAI 兼容 LLM 接口（在线 + 离线双模式） |

## 功能清单

- [x] 首页仪表盘（今日录音统计、最近记录）
- [x] 新建录音（标题、备注、描述、参与人员，标题自动生成）
- [x] 长时间录音（前台 + 后台音频模式）
- [x] 实时语音转写（WebSocket 流式 FunASR — **在线模式**，分段发送）
- [x] **离线语音转写（Sherpa-ONNX + SenseVoice 模型 — iOS 15.1+）**
- [x] ASR 模式切换（在线/离线），设置页 Toggle 开关
- [x] 离线 ASR 模型下载（INT8 ~158MB 压缩包 / FP32 ~845MB 压缩包），从 GitHub Releases 下载
- [x] 录音结束后自动生成结构化总结
- [x] **在线 LLM 总结（OpenAI 兼容 API，支持 DeepSeek 等）**
- [x] **离线 LLM 总结（llama.cpp + Qwen2.5 GGUF 本地推理）**
- [x] **LLM 模式切换（在线/离线）**，设置页独立 Toggle 开关
- [x] **离线 LLM 模型下载**（Qwen2.5-1.5B ~986MB / Qwen2.5-0.5B ~352MB），支持 ModelScope 下载和 GGUF 文件导入
- [x] **连接测试**（FunASR WebSocket + LLM API 连通性检测）
- [x] 录音详情（基本信息 + 完整转写文本 + AI 总结 + 音频回放）
- [x] 音频回放（播放/暂停、快进快退 15s、进度拖动）
- [x] 音频/转写文件导出（系统分享面板）
- [x] 历史记录（搜索、删除、清空全部）
- [x] 设置页面（ASR 模式、LLM 模式、FunASR 地址、LLM 配置、模型管理）

## 项目结构

```
ios/
├── README.md
├── project.yml                                 # XcodeGen 工程描述
├── generate_icon.py                            # 图标生成脚本
└── VoiceNote/
    ├── Libraries/                              # ⚠️ 预编译 XCFrameworks（不提交 git）
    │   ├── sherpa-onnx.xcframework             #   ~48MB
    │   └── onnxruntime.xcframework             #   ~126MB
    ├── VoiceNote.xcodeproj/                    # Xcode 工程文件
    └── VoiceNote/
        ├── VoiceNote.swift                     # @main App 入口 + 根导航
        ├── VoiceNote-Bridging-Header.h         # sherpa-onnx C API 桥接头
        ├── Info.plist                          # 权限、后台模式、Bundle 配置
        ├── Core/
        │   ├── ASR/
        │   │   ├── ASRTypes.swift              # ASRMode / ModelQuality 枚举
        │   │   ├── FunASRClient.swift          # FunASR WebSocket 客户端（在线）
        │   │   ├── OfflineASRClient.swift      # Sherpa-ONNX 离线客户端（iOS 15.1+）
        │   │   └── ModelDownloadManager.swift  # 离线 ASR 模型下载管理器（GitHub Releases）
        │   ├── Audio/
        │   │   ├── AudioCapture.swift          # AVAudioEngine PCM 采集
        │   │   └── AudioPlayer.swift           # AVAudioPlayer 音频回放
        │   ├── LLM/
        │   │   ├── LLMTypes.swift              # LLMMode / LLMModelInfo 枚举
        │   │   ├── LLMClient.swift             # OpenAI 兼容 LLM 客户端（在线）
        │   │   ├── OfflineLLMClient.swift      # llama.cpp 离线 LLM 客户端
        │   │   └── LLMModelManager.swift       # 离线 LLM 模型下载管理器（ModelScope）
        │   ├── Location/LocationTracker.swift  # GPS 位置追踪（预留，未接入）
        │   ├── Service/
        │   │   ├── RecordingManager.swift      # 前台+后台录音编排（在线/离线分发，分段 ASR + LLM 总结）
        │   │   └── ConnectionTester.swift      # WebSocket/LLM 连接测试
        │   ├── Database/PersistenceController.swift # Core Data 栈
        │   └── DI/AppContainer.swift           # 手动 DI 容器
        ├── Domain/
        │   ├── Model/
        │   │   ├── Visit.swift                 # VoiceRecord, ProcessingStatus
        │   │   └── VisitSummary.swift          # RecordSummary, TodoItem
        │   └── Repository/VisitRepository.swift # Repository 协议
        ├── Data/Repository/VisitRepositoryImpl.swift  # Core Data 实现
        └── UI/
            ├── Home/                           # 首页仪表盘
            ├── Recording/                      # 新建录音 + 实时转写 + 音频导入
            ├── Detail/                         # 录音详情 + AI 总结 + 音频回放
            ├── History/                        # 历史记录（搜索、删除）
            ├── Settings/
            │   ├── SettingsView.swift          # 设置主页面
            │   ├── SettingsViewModel.swift     # 设置逻辑
            │   ├── OfflineASRSettingsView.swift # 离线 ASR 模型管理
            │   └── OfflineLLMSettingsView.swift # 离线 LLM 模型管理
            └── Theme/AppTheme.swift            # 主题常量
```

## 环境要求

- macOS 12+（Xcode 14.2）
- Xcode 14.2+（Swift 5.7）
- iOS 14.0+（在线模式）/ iOS 15.1+（离线 ASR / 离线 LLM）

## 构建前准备

### 1. 下载 XCFrameworks（必须）

离线 ASR 依赖的 XCFrameworks 不提交 git（文件太大），首次 clone 后运行：

```bash
cd ios
bash ../scripts/download_ios_frameworks.sh
```

这会从 GitHub Releases 下载 `sherpa-onnx.xcframework` 和 `onnxruntime.xcframework`，放到 `VoiceNote/Libraries/` 下。

### 2. 打开工程

用 Xcode 打开 `VoiceNote/VoiceNote.xcodeproj`，选择真机运行。

> 注意：离线识别不支持模拟器（onnxruntime 仅支持 ARM64 真机）。

## 离线 ASR 使用流程

1. 打开 App → 设置
2. 打开「离线识别」开关
3. 选择模型质量：INT8（~158MB 压缩包，推荐）/ FP32（~845MB 压缩包）
4. 点击「下载」，从 GitHub Releases 拉取 tar.bz2 归档并自动解压
5. 下载完成后，新建录音即可开始录制 → 语音识别在本地完成

模型文件存储在设备沙盒 `Documents/models/sense-voice/`，不打包进 App。

## 离线 LLM 使用流程

1. 打开 App → 设置
2. 打开「离线总结」开关
3. 选择模型：Qwen2.5-1.5B（~986MB）/ Qwen2.5-0.5B（~352MB）/ 自定义
4. 点击「下载」从 ModelScope 拉取 GGUF 模型文件，或通过「上传」导入本地 GGUF 文件
5. 下载完成后，录音结束 → LLM 总结在本地完成（llama.cpp 推理）

模型文件存储在设备沙盒 `Documents/models/llm/`，不打包进 App。

## 离线 ASR 模型下载源

ASR 模型从 **GitHub Releases** 下载（`k2-fsa/sherpa-onnx` 仓库的 `asr-models` tag）。

> ⚠️ **注意**：ASR 模型不使用 HuggingFace（中国区无法访问），也不使用 ModelScope（原仓库已失效）。
> 如果 GitHub 链接失效，可去 [k2-fsa/sherpa-onnx Releases](https://github.com/k2-fsa/sherpa-onnx/releases) 搜索最新模型。

### 当前使用的模型（2025-09-09 版）

| 精度 | 归档文件名 | 压缩包大小 | 解压后模型大小 |
|------|-----------|-----------|---------------|
| INT8 | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` | ~158 MB | ~229 MB |
| FP32 | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2` | ~845 MB | ~895 MB |

### 下载 URL

```
https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{archiveFilename}
```

即：

| 精度 | 完整 URL |
|------|----------|
| INT8 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` |
| FP32 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2` |

### 归档内容

每个 tar.bz2 压缩包内包含：

```
sherpa-onnx-sense-voice-zh-en-ja-ko-yue-{int8-}2025-09-09/
├── model.int8.onnx   # 或 model.onnx（FP32 版）
├── tokens.txt         # 分词器，两个精度共用
├── README.md
└── test_wavs/         # 测试音频，App 不提取
```

App 下载后自动解压并提取 `model.int8.onnx`（或 `model.onnx`）和 `tokens.txt` 到沙盒目录。

### 如何寻找新模型

如果当前链接失效，按以下步骤找替换：

1. 访问 [sherpa-onnx Releases](https://github.com/k2-fsa/sherpa-onnx/releases)
2. 找到 `asr-models` tag（或最新 asr-models 发布）
3. 搜索 `sense-voice` 相关的 `.tar.bz2` 文件
4. 选择不带芯片前缀的通用版本（不要 `rk3562/rk3588/ascend/qnn` 等前缀）
   - 正确：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-{date}.tar.bz2`
   - 错误：`sherpa-onnx-rk3588-...-sense-voice-...tar.bz2`（特定芯片优化版）
5. INT8 版本文件名包含 `int8`，FP32 不包含
6. 更新 `ASRTypes.swift` 中的 `archiveFilename` 和 `estimatedSizeMB`

## 离线 LLM 模型下载源

LLM 模型（GGUF 格式）从 **ModelScope** 下载，支持手动导入本地 GGUF 文件。

| 模型 | 文件名 | 大小 |
|------|--------|------|
| Qwen2.5-1.5B | `qwen2.5-1.5b-instruct-q4_k_m.gguf` | ~986 MB |
| Qwen2.5-0.5B | `qwen2.5-0.5b-instruct-q4_k_m.gguf` | ~352 MB |

> 低内存设备（< 3GB RAM）自动使用 CPU-only 推理，避免 GPU 内存压力。
> 支持内存警告监听：收到系统内存警告时，推理完成后自动释放模型。

### 开发者下载脚本

项目根目录提供了下载脚本，可在电脑上提前下载模型：

```bash
# 下载两种精度
bash scripts/download_models.sh

# 只下载 INT8（推荐，158MB）
bash scripts/download_models.sh int8

# 只下载 FP32（845MB）
bash scripts/download_models.sh fp32
```

模型文件和 `tokens.txt` 会输出到 `models/sense-voice/` 目录，可传输到手机后用 App「上传」按钮导入。

## 权限

| 权限 | Info.plist Key | 用途 |
|---|---|---|
| 麦克风 | NSMicrophoneUsageDescription | 录音 |
| 后台音频 | UIBackgroundModes → audio | 锁屏/后台持续录音 |

## 注意事项

- 离线识别**最低要求 iOS 15.1**（onnxruntime 限制），iOS 14 设备上离线开关自动隐藏
- 离线 LLM 同样要求 iOS 15.1+（llama.cpp 框架限制）
- iOS 后台录音需配置 `UIBackgroundModes` 中的 `audio` 模式
- 通过 `AVAudioSession.setCategory(.playAndRecord)` 确保后台音频不中断
- FunASR WebSocket 在 App 进入后台时可能断开，已内置自动重连（最多 3 次，间隔 2/4/8 秒）
- 在线 LLM 调用失败时自动重试（最多 5 次，指数退避 5/10/20/40/80 秒）
- Core Data 数据模型为程序化构建，无需 `.xcdatamodeld` 文件
- 设置项存储在 `UserDefaults`，首次使用需在 App 设置页面配置
- 录音标题为空时自动生成（格式："新录音 M月d日 HH:mm"），类似 iOS 语音备忘录
