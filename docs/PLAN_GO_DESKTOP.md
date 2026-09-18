# 语音笔记桌面版（Go）移植计划

> 将 Android 版语音笔记（Kotlin + Compose + Room + Hilt + JNI）原封不动移植为两个桌面版本：
> - **Ubuntu**：最终打包为 AppImage
> - **Windows**：最终打包为不依赖系统的静态 exe
>
> 参考项目：`/home/rd/workspace/avatar/desktop`（Linux 数字人）、`/home/rd/workspace/avatar_win`（Windows 数字人）。

---

## 1. 总览

Android 项目是一个功能完整的语音笔记应用，包含 6 个页面：登录、首页、录音、详情、历史、设置。

核心功能链：

```
麦克风采集 → 离线 ASR 转写（sherpa-onnx SenseVoice）→ 在线 LLM 总结（OpenAI 兼容 API）→ 上传到服务器
```

桌面版要求**业务逻辑 1:1 保留**，中文 UI 文案完全不变，只是把平台相关 API 替换为桌面等价物。

---

## 2. 参考项目带来的关键结论

### 2.1 avatar/desktop（Linux）

| 方面 | 实现 |
|------|------|
| GUI | C 子进程（GTK3 + WebKit2GTK），stdin/stdout JSON IPC |
| 音频采集 | ALSA（CGo，`snd_pcm_readi`） |
| 音频播放 | ebitengine/oto |
| 离线 ASR | sherpa-onnx-go（SenseVoiceSmall int8） |
| 在线 ASR | DashScope Qwen-ASR WebSocket |
| 构建 | garble 混淆 |
| 打包 | tar.gz |

### 2.2 avatar_win（Windows）

| 方面 | 实现 |
|------|------|
| GUI | WebView2（Edge/Chromium），无边框窗口 |
| 音频采集 | WASAPI（go-wca + go-ole COM） |
| 音频播放 | ebitengine/oto |
| 离线 ASR | sherpa-onnx-go（SenseVoiceSmall int8） |
| 构建 | garble + `-H windowsgui` |
| 打包 | zip + sherpa-onnx DLL + 模型文件 |

### 2.3 关键洞察

1. **ASR/TTS/LLM/KWS/brain 等业务包完全没有平台 build tag**，跨平台共享。
2. **平台差异集中在两处**：GUI 渲染器 + 音频采集。通过 `//go:build` 文件后缀（`_windows.go` / `_linux.go`）区分。
3. **sherpa-onnx-go 官方 Go 绑定** 自带各平台原生库（`sherpa-onnx-go-linux` / `sherpa-onnx-go-windows`），无需手写 JNI/CMake。
4. 数字人用 WebView2/WebKitGTK 是为了 3D 渲染，语音笔记是纯表单/列表/文本应用，**不需要** 3D，应选更轻量的 Go GUI。

---

## 3. 技术选型

| 层 | 选择 | 理由 |
|---|------|------|
| **语言** | Go 1.24+ | 用户要求 |
| **GUI 框架** | **Fyne** | 纯 Go 跨平台，Material Design 风格，AppImage/静态 exe 均支持 |
| **离线 ASR** | sherpa-onnx-go | 与 avatar 一致，同一 SenseVoice 模型 |
| **音频采集** | 平台文件 + build tags | Linux: ALSA CGo；Windows: WASAPI（go-wca） |
| **音频播放** | ebitengine/oto v3 | 跨平台，avatar 已验证 |
| **数据库** | SQLite（`modernc.org/sqlite` 纯 Go） | 无 CGo 依赖，静态构建友好 |
| **HTTP** | `net/http` 标准库 | 替代 OkHttp |
| **JSON** | `encoding/json` 标准库 | 替代 Gson |
| **配置持久化** | JSON 文件 | 替代 DataStore |
| **并发** | goroutine + channel | 替代 Kotlin coroutines |
| **依赖注入** | 构造函数手动注入 | 替代 Hilt |
| **构建混淆** | garble `-literals` | 与 avatar 一致 |
| **Ubuntu 打包** | AppImage | 用户要求 |
| **Windows 打包** | 静态 exe + go-winres 图标 | 用户要求 |

### 为什么不用 WebView2/WebKitGTK？

数字人需要 3D 渲染才引入 WebView。语音笔记是标准业务表单应用（列表、文本、按钮、滑块），Fyne 更合适：

- 纯 Go，无 C 前端进程，单二进制
- 自带 Material Design 组件（Card、List、Entry、Slider、Dialog、Tab）
- 官方支持 `fyne package` 打包 AppImage 和 Windows exe

---

## 4. 项目结构

```
voice_note/
├── android/                          ← Android 版（不变）
├── ios/                              ← iOS 版（不变）
├── desktop/                          ← 共享 Go module（核心代码 100% 在这里）
│   ├── main.go                       # 入口
│   ├── go.mod / go.sum
│   ├── Makefile                      # Linux 构建脚本
│   ├── build.ps1                     # Windows 构建脚本（PowerShell）
│   ├── cfg.yml / cfg.yml.template    # 运行时配置（LLM API、服务器地址）
│   │
│   ├── internal/
│   │   ├── asr/
│   │   │   └── engine.go             # sherpa-onnx SenseVoice 离线 ASR（模型 go:embed 内置）
│   │   │
│   │   ├── audio/
│   │   │   ├── capture.go            # Recorder 接口 + 公共逻辑
│   │   │   ├── capture_linux.go      # ALSA 采集（build tag: linux）
│   │   │   ├── capture_windows.go    # WASAPI 采集（build tag: windows）
│   │   │   ├── playback.go           # oto 播放（跨平台）
│   │   │   ├── wav.go                # WAV 读写（替代 WavParser + AudioFileManager）
│   │   │   ├── importer.go           # 外部音频导入
│   │   │   └── pcm_util.go           # PCM 转换
│   │   │
│   │   ├── database/
│   │   │   ├── db.go                 # SQLite 连接 + migration
│   │   │   └── record_dao.go         # CRUD
│   │   │
│   │   ├── llm/
│   │   │   └── client.go             # OpenAI 兼容 LLM（替代 OnlineLLMClient）
│   │   │
│   │   ├── network/
│   │   │   └── server_client.go      # HTTP 上传（替代 ServerClient）
│   │   │
│   │   ├── service/
│   │   │   ├── recorder.go           # 录音编排器（替代 RecordingService）
│   │   │   ├── checkpoint.go         # 检查点/崩溃恢复
│   │   │   └── disk_monitor.go       # 磁盘空间监控
│   │   │
│   │   ├── settings/
│   │   │   └── store.go              # JSON 配置持久化（替代 SettingsDataStore）
│   │   │
│   │   └── common/
│   │       ├── time_util.go
│   │       └── memory_bus.go
│   │
│   ├── domain/
│   │   ├── voice_record.go           # VoiceRecord / RecordSummary 结构体
│   │   └── repository.go             # 仓库接口
│   │
│   ├── data/
│   │   └── repository_impl.go        # 仓库实现
│   │
│   ├── ui/
│   │   ├── theme.go                  # 颜色/字体/样式
│   │   ├── app.go                    # Fyne 主窗口 + 页面导航
│   │   ├── home/
│   │   │   ├── screen.go             # 首页（统计卡片 + 最近记录）
│   │   │   └── viewmodel.go
│   │   ├── login/
│   │   │   ├── screen.go             # 登录页
│   │   │   └── viewmodel.go
│   │   ├── recording/
│   │   │   ├── screen.go             # 录音页（实时转写 + 波形）
│   │   │   ├── viewmodel.go
│   │   │   └── waveform.go           # 音频波形自定义 Widget
│   │   ├── detail/
│   │   │   ├── screen.go             # 详情页（音频/转写/总结 三个 Tab）
│   │   │   ├── viewmodel.go
│   │   │   ├── playback.go           # 播放控制器
│   │   │   ├── transcript.go         # 转写控制器
│   │   │   ├── summary.go            # 总结控制器
│   │   │   └── upload.go             # 上传控制器
│   │   ├── history/
│   │   │   ├── screen.go             # 历史记录（搜索 + 滑动删除）
│   │   │   └── viewmodel.go
│   │   └── settings/
│   │       ├── screen.go             # 设置页（LLM + 服务器配置）
│   │       └── viewmodel.go
│   │
│   └── winres/                       # Windows 资源文件
│       ├── icon.png
│       └── winres.json
├── docs/
│   └── PLAN_GO_DESKTOP.md            # 本文件
├── scripts/                          # 全局脚本（不变）
└── README.md
```

---

## 5. Android → Go 映射

| Android | Go Desktop |
|---------|-----------|
| Room (SQLite) | `database/sql` + `modernc.org/sqlite`（纯 Go） |
| Hilt DI | 构造函数手动注入 |
| DataStore Preferences | JSON 文件 |
| AudioRecord | ALSA（Linux）/ WASAPI（Windows） |
| AudioTrack | ebitengine/oto |
| OkHttp | `net/http` |
| Gson | `encoding/json` |
| Kotlin Coroutines StateFlow | goroutine + channel + Fyne DataBinding |
| Jetpack Compose | Fyne widgets |
| Navigation Compose | Fyne 手动 Stack 导航 |
| JNI（sherpa-onnx C API） | sherpa-onnx-go（自动处理） |
| Foreground Service | 后台 goroutine |
| Notification | 系统通知（fyne 托盘） |
| BuildConfig | `-ldflags -X` |
| proguard-rules | garble `-literals` |
| FileProvider | 直接文件路径 |
| 权限系统 | 无需（桌面无权限模型） |

---

## 6. 关键模块实现要点

### 6.1 离线 ASR（`internal/asr/engine.go`）

ASR 模型（int8 ~170MB）、VAD 模型、标点模型通过 `//go:embed` 嵌入二进制，首次运行解压到用户数据目录，之后直接读取。绑定死、无运行时下载：

- 模型：`model.int8.onnx`（SenseVoiceSmall int8）+ `tokens.txt`
- VAD：`silero_vad.onnx`
- 标点：`punct_ct_transformer.onnx`
- 16kHz、feature_dim 80、language auto、use_itn、greedy_search
- `AcceptWaveform` → `Decode` → `GetResult()`

### 6.2 音频采集（`internal/audio/capture_*.go`）

- **接口**：`Start() (<-chan []float32, error)` + `Stop()`
- **Linux**：ALSA CGo（`snd_pcm_readi`），从 avatar/desktop 提取
- **Windows**：WASAPI（go-wca + go-ole COM），从 avatar_win 提取
- 16kHz mono int16 → float32 [-1,1]

### 6.3 数据库（`internal/database/`）

SQLite schema 对齐 Room v8 的 `voice_records` 表：

```sql
CREATE TABLE voice_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    memo TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    speakers_json TEXT NOT NULL DEFAULT '[]',
    source_type TEXT NOT NULL DEFAULT 'RECORDING',
    start_time INTEGER NOT NULL,
    end_time INTEGER,
    audio_file_path TEXT NOT NULL DEFAULT '',
    transcript_file_path TEXT NOT NULL DEFAULT '',
    transcript_status TEXT NOT NULL DEFAULT 'PENDING',
    created_at INTEGER NOT NULL,
    summary_json TEXT NOT NULL DEFAULT '',
    summary_status TEXT NOT NULL DEFAULT 'PENDING',
    summary_generated_at INTEGER,
    server_record_id TEXT NOT NULL DEFAULT ''
);
```

### 6.4 录音编排器（`internal/service/recorder.go`）

对应 Android RecordingService 的完整逻辑：

- 麦克风采集 → WAV 写入（含 header patch）
- VAD 语音活动检测（sherpa-onnx Silero VAD）
- 增量解码（5 秒窗口 + 2 秒 overlap）
- 检查点机制（2 分钟一次，崩溃恢复）
- 磁盘空间监控（5 分钟一次，<500MB 告警）
- 标点恢复（sherpa-onnx punctuation，分块处理）

### 6.5 在线 LLM 总结（`internal/llm/client.go`）

对应 OnlineLLMClient：

- OpenAI 兼容 API（DeepSeek 等）
- 长文本分段：`MAX_CHUNK_CHARS = 8000`，分块摘要 → 汇总合并
- 指数退避重试（3 次）
- system prompt 完全一致（JSON 输出格式：topics/conclusions/todos/nextSteps）

### 6.6 服务器上传（`internal/network/server_client.go`）

对应 ServerClient：

- `POST /api/auth/login` → token
- `POST /api/records` → multipart（metadata JSON + audio file）
- businessId 生成（yyyyMMddHHmmssSSS）

---

## 7. UI 页面清单

| 页面 | 对应 Android 文件 | 主要组件 |
|------|------------------|---------|
| 登录 | LoginScreen.kt | 用户名/密码输入、登录按钮、跳过 |
| 首页 | HomeScreen.kt | 统计卡片、模型状态横幅、最近记录列表 |
| 录音 | RecordingScreen.kt | 脉冲红点、波形、实时转写、结束按钮 |
| 详情 | DetailScreen.kt | 3 Tab（音频/转写/总结）、播放器、上传 |
| 历史 | HistoryScreen.kt | 搜索框、滑动删除、列表 |
| 设置 | SettingsScreen.kt | LLM 配置、服务器配置、连接测试 |

---

## 8. 构建与打包

### 8.1 模型资源（`//go:embed`）

ASR 模型（int8 ~170MB）、VAD 模型、标点模型通过 `//go:embed` 嵌入二进制，首包体积增大但离线开箱即用。运行时解压到用户数据目录（`~/.voicenote/models/` 或 `%APPDATA%\VoiceNote\models\`），首次运行才解压，之后直接读取。

### 8.2 Ubuntu（AppImage）

```bash
# 在 desktop/ 目录下执行

# 开发构建
go build -o voice-note .

# 混淆构建
GOTOOLCHAIN=local GOGARBLE=github.com/liuyngchng/voice-note-desktop \
  go run mvdan.cc/garble@v0.14.2 -literals build -o voice-note .

# AppImage 打包（模型已 embed，单文件）
fyne package -os linux -icon winres/icon.png --appID com.voicenote.desktop
```

### 8.3 Windows（静态 exe + sherpa-onnx DLL）

```powershell
# 在 desktop\ 目录下执行

# 图标资源（go-winres）
go install github.com/tc-hib/go-winres@latest
go generate ./...

# 混淆构建 + 无控制台窗口
go run mvdan.cc/garble@v0.14.2 -literals build `
  -ldflags="-s -w -H windowsgui" `
  -o dist/voice-note.exe .

# 打包（exe + sherpa-onnx DLL；模型已 embed 进 exe）
# 目录结构：
# dist/
#   voice-note.exe
#   onnxruntime.dll
#   sherpa-onnx-c-api.dll
#   sherpa-onnx-cxx-api.dll
```

---

## 9. 实现顺序（约 38 个文件）

1. **domain/** — 数据结构（零依赖）
2. **database/** — SQLite schema + CRUD
3. **settings/** — JSON 配置
4. **common/** — 工具函数
5. **asr/** — 离线 ASR 引擎（从 avatar 提取模式）
6. **audio/** — 平台音频采集 + 播放 + WAV
7. **llm/** + **network/** — 在线 LLM 总结 + 服务器上传
8. **data/** — 仓库层
9. **service/** — 录音编排 + 检查点
10. **ui/theme.go** — 样式系统
11. **ui/home, login, history, settings** — 4 个简单页面
12. **ui/recording** — 录音页（最复杂，含实时波形）
13. **ui/detail** — 详情页（3 Tab + 播放 + 转写 + 总结 + 上传）
14. **ui/app.go** — 导航壳
15. **main.go** — 入口
16. **Makefile / build.ps1** — 构建脚本

---

## 10. 与 Android 版差异总结

| 差异点 | 说明 |
|--------|------|
| 无需 VAD/Punctuation JNI | sherpa-onnx-go 原生支持，无 JNI 桥 |
| 无需 Hilt | Go 手动依赖注入更直接 |
| 无需权限系统 | 桌面无 Android 权限模型 |
| 无需 Foreground Service | 后台 goroutine 直接跑 |
| 无需 FileProvider | 直接文件路径 |
| 无模型管理 UI | 模型 go:embed 内置绑定死，移除设置页的模型下载/上传/删除功能 |
| 单模块双平台 | build tags 区分，核心代码 100% 共享 |

---

## 11. 已确认事项

1. **GUI 框架**：**Fyne**（纯 Go 跨平台）

   > 答复：我看你用了webkit，这种相当于是一个网页，这种长时间录音的场景OK吗？
   >
   > **结论**：avatar 用 WebKit/WebView2 是为了跑 three.js 的 3D 数字人渲染，属于不得不走浏览器内核的场景。语音笔记是纯表单/列表/文本应用，**Fyne 更合适**——直接调用原生图形 API 渲染（不走浏览器），无 WebView 进程崩溃风险，长时间录音更稳定。决定采用 Fyne。

2. **SQLite 驱动**：**`modernc.org/sqlite`**（纯 Go）

   > 答复：必然是纯go版本
   >
   > **结论**：使用纯 Go 实现的 `modernc.org/sqlite`，无 CGo 依赖，Windows 静态 exe 和 Linux AppImage 都更友好。

3. **模型文件分发**：**随包分发（embed 进二进制，绑定死）**

   > 答复：模型文件直接打到AppImage包/windows exe里
   >
   > 补充答复：咱都内置了，没必要再在设置页面保留「模型下载/上传」选项，内置直接绑定死就行
   >
   > **结论**：ASR 模型（int8 ~170MB）、VAD 模型、标点模型通过 `//go:embed` 嵌入二进制，绑定死。离线开箱即用，无运行时下载依赖。**设置页不再提供「模型下载/上传/删除」选项**，模型管理相关 UI 整体移除。

4. **Windows 依赖**：**携带 sherpa-onnx DLL**

   > 答复：需要携带 sherpa-onnx DLL，不然在windows上那不缺少依赖嘛
   >
   > **结论**：Windows 分发时 exe 旁边携带 sherpa-onnx 运行时 DLL（onnxruntime.dll、sherpa-onnx-c-api.dll、sherpa-onnx-cxx-api.dll），与 avatar_win 一致。Linux 侧 sherpa-onnx-go 静态链接 .so，AppImage 内联。
