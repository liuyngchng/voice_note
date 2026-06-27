# 语音笔记

语音笔记是一款 Android / iOS 双平台应用，支持离线语音转写（ASR）。录制或导入音频后，自动将语音转为文字。

## 功能

- **录音与导入** — 实时录音（Android 前台服务 + WakeLock 保活 / iOS 后台音频模式）；Android 版额外支持从本地导入音频文件
- **离线语音转写** — 本地 Sherpa-ONNX + SenseVoice 模型（INT8 / FP32），无需网络
- **离线标点恢复** — 可选下载 CT-Transformer 模型，给转写文本自动添加标点符号
- **音频回放** — 播放/暂停、快进快退 15s、进度拖动、分享导出
- **历史记录** — 按标题/备注/内容搜索，侧滑删除，批量清空

## Android 版技术栈

| 项 | 选型 |
|---|---|
| 语言 | Kotlin |
| UI | Jetpack Compose + Material 3 |
| 架构 | MVVM + Clean Architecture |
| DI | Hilt |
| 本地存储 | Room (SQLite) + DataStore |
| 网络 | OkHttp（模型下载） |
| 录音 | AudioRecord 16kHz/16bit/PCM |
| 离线 ASR | Sherpa-ONNX JNI + SenseVoice (INT8/FP32 ONNX) |
| 离线标点 | CT-Transformer ONNX（可选下载） |
| VAD | Silero VAD ONNX（内置打包） |
| 原生构建 | CMake + NDK (arm64-v8a) |

## iOS 版技术栈

| 项 | 选型 |
|---|---|
| 语言 | Swift 5 |
| UI | SwiftUI（iOS 14 兼容） |
| 架构 | MVVM + 手动 DI |
| 本地存储 | Core Data + UserDefaults |
| 录音 | AVAudioEngine 16kHz/16bit/PCM |
| 离线 ASR | Sherpa-ONNX XCFramework + SenseVoice (INT8/FP32 ONNX) |
| 离线标点 | CT-Transformer ONNX（可选下载） |

## 快速开始

### Android

1. 用 Android Studio 打开项目根目录
2. 等待 Gradle Sync 完成
3. 连接 Android 设备或启动模拟器（API ≥ 26，需 arm64-v8a）
4. 运行 App

### iOS

1. 用 Xcode 打开 `ios/VoiceNote/VoiceNote.xcodeproj`
2. 选择目标设备（iOS 14.0+）
3. 运行 App
4. 首次启动会提示下载/导入 SenseVoice 语音识别模型

## 配置

首次使用在 App 内 **设置** 页面配置。

### 通用配置（双平台）

| 配置项 | 说明 | 默认值 |
|---|---|---|
| ASR 模型质量 | INT8 (~170MB) / FP32 (~860MB) | INT8 |
| 标点符号模型 | 可选，用于给转写文本自动添加标点 | 未安装 |

> 低内存设备（< 4GB RAM）不建议使用 FP32 模型。

### 模型获取

**ASR 模型**从 GitHub Releases 自动下载 `.tar.bz2` 归档并解压，也支持从本地文件导入（`.tar.bz2`、`.tar` 或 `.onnx` 文件）。

**标点模型**从 GitHub Releases 下载，也支持从本地文件导入。

| 模型 | 大小 | 下载地址 |
|---|---|---|
| ASR INT8 | ~170 MB | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2` |
| ASR FP32 | ~860 MB | `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar.bz2` |
| 标点模型 | ~1 MB | `https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2` |

> Android 版 VAD 模型已内置在安装包中，无需额外下载。

## 使用流程

### iOS

1. **首页** — 查看今日录音统计、最近录音列表
2. **新建录音**（点击 ＋）— 直接开始录音，标题自动生成
3. **录音中** — 界面顶部变红，显示脉冲红点 + 计时器，下方实时滚动显示离线语音转写文本
4. **结束录音** — 点击红色按钮，自动保存音频和转写结果（含标点恢复，如已安装标点模型）
5. **查看详情** — 两个 Tab 页切换：音频回放 / 完整转写，支持重新转写、导出分享
6. **历史记录** — 按标题/备注搜索，左滑删除单条，右上角清空全部

### Android

1. **首页** — 查看今日录音统计、最近录音列表
2. **新建录音**（点击 +）— 填写标题、备注、说话人（均可选），点击「开始录音」；或点击「导入音频」从本地选取音频文件
3. **录音中** — 前台服务持续录音，界面实时显示语音转写文本
4. **结束录音** — 自动保存音频和转写结果（含标点恢复，如已安装标点模型）
5. **查看详情** — 两个 Tab 页切换：音频回放 / 完整转写，支持重新转写、导出分享
6. **历史记录** — 按标题/备注/内容搜索，侧滑删除单条，右上角清空全部

## iOS 项目结构

```
ios/VoiceNote/VoiceNote/
├── VoiceNote.swift                     # App 入口 + 启动模型加载 + 导航
├── Core/
│   ├── ASR/
│   │   ├── ASRTypes.swift              # 模型质量枚举
│   │   ├── ASRModelManager.swift       # ASR 模型下载/导入/删除
│   │   ├── OfflineASRClient.swift      # Sherpa-ONNX C API 客户端
│   │   ├── OfflinePunctuationClient.swift # 标点模型 C API 客户端
│   │   ├── PunctuationModelManager.swift # 标点模型下载/导入/删除
│   │   └── Bzip2Helper.h              # bzip2 解压 C 桥接
│   ├── Audio/
│   │   ├── AudioCapture.swift          # AVAudioEngine PCM 采集
│   │   └── AudioPlayer.swift           # 录音回放
│   ├── Service/
│   │   └── RecordingManager.swift      # 录音 + 离线 ASR + 标点编排
│   ├── Database/
│   │   └── PersistenceController.swift # Core Data
│   ├── Location/
│   └── DI/
│       └── AppContainer.swift          # 手动依赖注入
├── Domain/
│   ├── Model/
│   │   ├── Visit.swift                 # VoiceRecord 领域模型
│   │   └── VisitSummary.swift          # 总结数据模型（规划中）
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
│   │   ├── AudioFileManager.kt        # WAV 文件读写
│   │   └── AudioImporter.kt           # 外部音频导入 + 后台 ASR
│   ├── asr/
│   │   ├── ASRMode.kt                 # ASR 模式枚举
│   │   ├── ModelQuality.kt            # SenseVoice 模型精度（INT8/FP32）
│   │   ├── OfflineASRClient.kt        # Sherpa-ONNX JNI 客户端（离线）
│   │   └── ASRModelManager.kt         # 离线 ASR 模型下载/上传/删除
│   ├── service/RecordingService.kt    # 前台服务（录音 + ASR 编排）
│   ├── common/MemoryWarningBus.kt     # 内存警告事件总线
│   ├── database/                      # Room 数据库（Entity / DAO）
│   └── di/                            # Hilt 模块 + DataStore
├── domain/
│   ├── model/                         # VoiceRecord 领域模型
│   └── repository/                    # Repository 接口
├── data/repository/                   # Repository 实现
└── ui/
    ├── home/                          # 首页仪表盘
    ├── recording/                     # 新建录音 + 实时转写 + 音频导入
    ├── detail/                        # 录音详情（音频 / 转写两个 Tab）
    ├── history/                       # 历史记录（搜索 + 侧滑删除）
    ├── settings/                      # ASR 模型质量 + 模型管理
    ├── navigation/                    # 路由
    └── theme/                         # Material 3 主题
```

## 权限

| 权限 | 用途 | 平台 |
|---|---|---|
| RECORD_AUDIO / 麦克风 | 录音 | Android / iOS |
| INTERNET | 模型下载 | Android |
| FOREGROUND_SERVICE | 前台服务运行 | Android |
| WAKE_LOCK | 防止 CPU 休眠中断录音 | Android |

## 数据模型

```
VoiceRecord:
  id, title, memo, description, speakers,
  startTime, endTime, audioFilePath, transcriptFilePath,
  transcriptText, transcriptStatus (PENDING / PROCESSING / COMPLETED / UNAVAILABLE),
  summary (RecordSummary), summaryStatus, summaryGeneratedAt  ← 预留字段，规划中

RecordSummary:
  topics, conclusions, todos (TodoItem), nextSteps

TodoItem:
  task, owner, deadline
```

## 最低要求

- **Android** 8.0 (API 26)，离线 ASR 需 arm64-v8a 设备
- **iOS** 14.0
