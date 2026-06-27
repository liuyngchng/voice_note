# 语音笔记

语音笔记是一款 Android / iOS 双平台应用，支持离线语音转写（ASR）。录制或导入音频后，自动将语音转为文字。

## 功能

- **录音与导入** — 实时录音（前台服务 + WakeLock 保活 / 后台音频模式），支持从本地导入音频文件
- **离线语音转写** — 本地 Sherpa-ONNX + SenseVoice 模型（INT8 / FP32），无需网络
- **音频回放** — 播放/暂停、快进快退 15s、进度拖动、分享导出
- **历史记录** — 按标题/备注/内容搜索，侧滑删除，批量清空
- **标点符号模型** — 可选下载，给转写文本自动添加标点

## Android 版技术栈

| 项 | 选型 |
|---|---|
| 语言 | Kotlin 2.0 |
| UI | Jetpack Compose + Material 3 |
| 架构 | MVVM + Clean Architecture |
| DI | Hilt |
| 本地存储 | Room + DataStore |
| 网络 | OkHttp (REST + WebSocket) |
| 录音 | AudioRecord 16kHz/16bit/PCM |
| 在线 ASR | 私有化 FunASR (WebSocket 实时流式) |
| 离线 ASR | Sherpa-ONNX JNI + SenseVoice (INT8/FP32 ONNX) |
| 在线 LLM | OpenAI 兼容接口 (分段总结 + 带退避重试) |
| 离线 LLM | llama.cpp JNI + Qwen2.5 GGUF (0.5B/1.5B) |
| 原生构建 | CMake + NDK (arm64-v8a) |

## iOS 版技术栈

| 项 | 选型 |
|---|---|
| 语言 | Swift 5.0 |
| UI | SwiftUI (iOS 14 兼容) |
| 架构 | MVVM + 手动 DI |
| 本地存储 | Core Data + UserDefaults |
| 录音 | AVAudioEngine 16kHz/16bit/PCM |
| 离线 ASR | Sherpa-ONNX XCFramework + SenseVoice (INT8/FP32 ONNX) |
| VAD | Silero VAD ONNX 模型（内置打包） |
| 标点模型 | CT-Transformer ONNX（可选下载） |

## 快速开始

### Android

1. 用 Android Studio 打开项目目录
2. 等待 Gradle Sync 完成
3. 连接 Android 设备或启动模拟器（API ≥ 26）
4. 运行 App

### iOS

1. 用 Xcode 打开 `ios/VoiceNote/VoiceNote.xcodeproj`
2. 选择目标设备（iOS 14.0+）
3. 运行 App
4. 首次启动会提示下载/导入 SenseVoice 语音识别模型

## 配置 — iOS

首次使用在 App 内 **设置** 页面配置：

| 配置项 | 说明 | 默认值 |
|---|---|---|
| ASR 模型质量 | INT8 (~170MB) / FP32 (~860MB) | INT8 |
| 标点符号模型 | 可选，用于给转写文本自动添加标点 | 未安装 |

### 模型获取

**ASR 模型**从 GitHub Releases 自动下载 `.tar.bz2` 归档并解压，也支持从本地文件导入。

**标点模型**从 GitHub Releases 下载，也支持从本地文件导入。

| 模型 | 大小 | 下载地址 |
|---|---|---|
| ASR INT8 | ~170 MB | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` |
| ASR FP32 | ~860 MB | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2` |
| 标点模型 | ~1 MB | `https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2` |

> 低内存设备（< 4GB RAM）不建议使用 FP32 模型。VAD 模型已内置在安装包中，无需额外下载。
>
> 标点模型为单个 tar.bz2 归档，App 内点击「下载」可自动下载并解压提取 ONNX 文件。

## 配置 — Android

首次使用可在 App 内 **设置** 页面配置：

| 配置项 | 说明 | 默认值 |
|---|---|---|
| ASR 模式 | 在线 (FunASR) / 离线 (SenseVoice) | 离线 |
| FunASR WebSocket 地址 | 在线模式下的私有化 FunASR 服务地址 | `ws://192.168.240.29:10095` |
| 离线 ASR 模型质量 | INT8 (~170MB) / FP32 (~860MB) | INT8 |
| LLM 模式 | 在线 (API) / 离线 (本地模型) | 离线 |
| LLM API 地址 | OpenAI 兼容的 base_url 端点 | `https://api.deepseek.com` |
| LLM API Key | API 密钥 | — |
| LLM 模型 | 在线模式下的模型名称 | `deepseek-v4-pro` |
| 离线 LLM 模型 | Qwen2.5-1.5B / Qwen2.5-0.5B / 自定义 | Qwen2.5-0.5B |
| 自定义 Prompt | 总结 Prompt 模板（可选） | 留空使用默认 |

Android 离线模型下载详情见下方模型列表。

| 模型 | 文件 | 大小 | 下载地址 |
|---|---|---|---|
| ASR INT8 | `model.int8.onnx` + `tokens.txt` | ~170 MB | [GitHub Releases](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2) |
| ASR FP32 | `model.onnx` + `tokens.txt` | ~860 MB | [GitHub Releases](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2) |
| LLM Qwen2.5-0.5B | `qwen2.5-0.5b-instruct-q4_k_m.gguf` | ~352 MB | [ModelScope](https://modelscope.cn/models/qwen/Qwen2.5-0.5B-Instruct-gguf/resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf) |
| LLM Qwen2.5-1.5B | `qwen2.5-1.5b-instruct-q4_k_m.gguf` | ~986 MB | [ModelScope](https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf) |

## iOS 使用流程

1. **首页** — 查看今日录音统计、最近录音列表
2. **新建录音**（点击 ＋）— 直接开始录音，无需填写表单；也可点击导入按钮从本地选取音频文件
3. **录音中** — 界面顶部变红，显示脉冲红点 + 计时器，下方实时滚动显示离线语音转写文本
4. **结束录音** — 点击红色按钮，自动保存音频和转写结果
5. **查看详情** — 两个 Tab 页切换：音频回放 / 完整转写，支持重新转写、导出分享
6. **历史记录** — 按标题/备注搜索，左滑删除单条，右上角清空全部

## Android 使用流程

1. **首页** — 查看今日录音统计、最近录音列表
2. **新建录音**（点击 +）— 填写标题、备注、说话人（均可选），点击「开始录音」；或点击「导入音频」从本地选取音频文件
3. **录音中** — 前台服务持续录音，界面实时显示语音转写文本，支持在线/离线双模式
4. **结束录音** — 自动调用 LLM 生成结构化总结（议题 / 结论 / 待办 / 跟进计划），失败时自动重试
5. **查看详情** — 三个 Tab 页切换：音频回放 / 完整转写 / AI 总结，支持重新转写、重新总结、导出分享
6. **历史记录** — 按标题/备注/内容搜索，侧滑删除单条，右上角清空全部

## iOS 项目结构

```
ios/VoiceNote/VoiceNote/
├── VoiceNote.swift                     # App 入口 + 启动模型加载
├── Core/
│   ├── ASR/
│   │   ├── ASRTypes.swift              # 模型质量枚举
│   │   ├── OfflineASRClient.swift      # Sherpa-ONNX C API 客户端
│   │   ├── ModelDownloadManager.swift  # ASR 模型下载/导入/删除
│   │   └── PunctuationModelManager.swift # 标点模型下载/导入/删除
│   ├── Audio/
│   │   ├── AudioCapture.swift          # AVAudioEngine PCM 采集
│   │   └── AudioPlayer.swift           # 录音回放
│   ├── Service/
│   │   └── RecordingManager.swift      # 录音 + ASR 编排
│   ├── Database/
│   │   └── PersistenceController.swift # Core Data
│   └── DI/
│       └── AppContainer.swift          # 手动依赖注入
├── Domain/
│   ├── Model/
│   │   ├── Visit.swift                 # VoiceRecord 领域模型
│   │   └── VisitSummary.swift          # 总结数据模型
│   └── Repository/
│       └── VisitRepository.swift       # 数据仓库接口
├── Data/
│   └── Repository/
│       └── VisitRepositoryImpl.swift   # Core Data 仓库实现
└── UI/
    ├── Home/                           # 首页仪表盘
    ├── Recording/                      # 录音页（进入即开始）
    ├── Detail/                         # 录音详情（音频 / 转写两个 Tab）
    ├── History/                        # 历史记录
    ├── Settings/                       # 设置（ASR 模型 + 标点模型）
    └── Theme/                          # 主题常量
```

## Android 项目结构

```
app/src/main/java/com/voicenote/app/
├── VoiceNoteApp.kt                    # Application
├── MainActivity.kt                    # 入口 Activity
├── core/
│   ├── audio/
│   │   ├── AudioCapture.kt            # AudioRecord PCM 采集
│   │   ├── AudioFileManager.kt        # WAV 文件写入（PCM → WAV 头）
│   │   └── AudioImporter.kt           # 外部音频导入 + 后台 ASR/LLM
│   ├── asr/
│   │   ├── ASRMode.kt                 # 在线/离线模式枚举
│   │   ├── ModelQuality.kt            # SenseVoice 模型精度（INT8/FP32）
│   │   ├── FunASRClient.kt            # FunASR WebSocket 客户端（在线）
│   │   ├── OfflineASRClient.kt        # Sherpa-ONNX JNI 客户端（离线）
│   │   └── ASRModelManager.kt         # 离线 ASR 模型下载/上传/删除
│   ├── llm/
│   │   ├── LLMMode.kt                 # 在线/离线模式枚举
│   │   ├── LLMModelInfo.kt            # 离线 LLM 模型信息
│   │   ├── LLMClient.kt              # OpenAI 兼容 LLM 客户端（在线）
│   │   ├── OfflineLLMClient.kt       # llama.cpp JNI 客户端（离线）
│   │   ├── LlamaBridge.kt            # llama.cpp JNI 桥接
│   │   └── LLMModelManager.kt        # 离线 LLM 模型下载/上传/删除
│   ├── service/RecordingService.kt    # 前台服务（录音 + ASR + LLM 编排）
│   ├── network/ConnectivityChecker.kt # ASR/LLM 连接测试
│   ├── common/MemoryWarningBus.kt     # 内存警告事件总线
│   ├── database/                      # Room 数据库（Entity / DAO）
│   └── di/                            # Hilt 模块 + DataStore
├── domain/
│   ├── model/                         # VoiceRecord, VoiceRecordSummary, TodoItem
│   └── repository/                    # Repository 接口
├── data/repository/                   # Repository 实现
└── ui/
    ├── home/                          # 首页仪表盘
    ├── recording/                     # 新建录音 + 实时转写 + 音频导入
    ├── detail/                        # 录音详情（音频 / 转写 / 总结三个 Tab）
    ├── history/                       # 历史记录（搜索 + 侧滑删除）
    ├── settings/                      # API 配置 + ASR/LLM 模式切换 + 模型管理
    ├── navigation/                    # 路由
    └── theme/                         # Material 3 主题
```

## 权限

| 权限 | 用途 | 平台 |
|---|---|---|
| RECORD_AUDIO / 麦克风 | 录音 | Android / iOS |
| INTERNET | 网络通信（Android 在线 ASR/LLM） | Android |
| FOREGROUND_SERVICE | 前台服务运行 | Android |
| WAKE_LOCK | 防止 CPU 休眠中断录音 | Android |

## 数据模型

```
VoiceRecord:
  id, title, memo, description, speakers,
  startTime, endTime, audioFilePath, transcriptFilePath,
  transcriptText, transcriptStatus (PENDING / PROCESSING / COMPLETED / UNAVAILABLE),
  summary (RecordSummary), summaryStatus, summaryGeneratedAt

RecordSummary:
  topics, conclusions, todos (TodoItem), nextSteps

TodoItem:
  task, owner, deadline
```

## 最低要求

- **Android** 8.0 (API 26)，离线 ASR/LLM 需 arm64-v8a 设备
- **iOS** 14.0，离线 ASR 需 iOS 15.1+
