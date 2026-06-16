# 智能工牌

App 自动记录时间、地点、任务、人物等信息，通过 WebSocket 实时将音频流送至私有化 FunASR 做语音转文本，拜访结束后通过 LLM 自动生成结构化拜访记录。

## 技术栈

| 项 | 选型 |
|---|---|
| 语言 | Kotlin |
| UI | Jetpack Compose + Material 3 |
| 架构 | MVVM + Clean Architecture |
| DI | Hilt |
| 本地存储 | Room + DataStore |
| 网络 | OkHttp (REST + WebSocket) |
| 录音 | AudioRecord 16kHz/16bit/PCM |
| 定位 | LocationManager (系统 GPS) |
| ASR | 私有化 FunASR (WebSocket 实时流式) |
| AI 总结 | OpenAI 兼容接口 |

## 快速开始

1. 用 Android Studio 打开项目目录
2. 等待 Gradle Sync 完成
3. 连接 Android 设备或启动模拟器（API ≥ 26）
4. 运行 App

## 配置

首次使用需在 App 内 **设置** 页面配置：

| 配置项 | 说明 | 示例 |
|---|---|---|
| FunASR WebSocket 地址 | 私有化部署的 FunASR 服务地址 | `ws://192.168.1.100:10095` |
| LLM API 地址 | OpenAI 兼容的 chat completions 端点 | `https://api.openai.com/v1/chat/completions` |
| LLM API Key | API 密钥 | `sk-xxx` |
| LLM 模型 | 模型名称 | `gpt-4o-mini` |
| 自定义 Prompt | 总结 Prompt 模板（可选） | 留空使用默认 |

## 使用流程

1. **首页** — 查看今日拜访统计、最近记录
2. **新建拜访**（点击 +）— 填写客户名称、公司、拜访目的、参与人员
3. **开始录音** — 进入录制界面，实时显示语音转写文本
4. **结束拜访** — 自动调用 LLM 生成结构化总结（议题/结论/待办/跟进计划）
5. **查看详情** — 浏览完整转写文本和 AI 总结
6. **历史记录** — 按客户名称或公司搜索历史拜访

## 项目结构

```
app/src/main/java/com/smartbadge/app/
├── SmartBadgeApp.kt              # Application
├── MainActivity.kt               # 入口 Activity
├── core/
│   ├── audio/AudioCapture.kt     # AudioRecord PCM 采集
│   ├── asr/FunASRClient.kt       # FunASR WebSocket 客户端
│   ├── llm/LLMClient.kt          # OpenAI 兼容 LLM 客户端
│   ├── location/LocationTracker.kt  # GPS 位置追踪
│   ├── service/RecordingService.kt  # Foreground Service
│   ├── database/                 # Room 数据库
│   └── di/                       # Hilt 模块 + DataStore
├── domain/
│   ├── model/                    # Visit, VisitSummary
│   └── repository/               # Repository 接口
├── data/repository/              # Repository 实现
└── ui/
    ├── home/                     # 首页仪表盘
    ├── recording/                # 新建拜访 + 实时转写
    ├── detail/                   # 拜访详情 + AI 总结
    ├── history/                  # 历史记录
    ├── settings/                 # API 配置
    ├── navigation/               # 路由
    └── theme/                    # Material 3 主题
```

## 权限

| 权限 | 用途 |
|---|---|
| RECORD_AUDIO | 录音 |
| ACCESS_FINE_LOCATION | 记录拜访位置 |
| POST_NOTIFICATIONS | 前台服务通知 |
| INTERNET | 网络通信（ASR + LLM） |

## 数据模型

```
Visit:
  id, clientName, clientCompany, purpose, participants,
  startTime, endTime, locationPoints,
  transcriptText, summary (VisitSummary), audioFilePath

VisitSummary:
  topics, conclusions, todos (TodoItem), nextSteps

TodoItem:
  task, owner, deadline
```

## 最低要求

- Android 8.0 (API 26)
