@echo off
setlocal enabledelayedexpansion
title Building Voice Note Desktop

:: ============================================================
:: build.bat - Build Voice Note Desktop as a single static EXE
::
:: Models are embedded via Go's embed package (build tag: embed).
:: DLLs are bundled via a self-extracting Go launcher.
:: Output: voice-note.exe (single file, ~1.25 GB)
:: ============================================================

cd /d "%~dp0"
echo [BUILD] Voice Note Desktop
echo [BUILD] Working directory: %CD%

:: ----------------------------------------------------------
:: 1. Check prerequisites
:: ----------------------------------------------------------
echo.
echo [1/7] Checking environment...

where go >nul 2>&1 || (echo ERROR: go not found in PATH & exit /b 1)
where gcc >nul 2>&1 || (echo ERROR: gcc (MinGW-w64) not found in PATH & exit /b 1)
where tar >nul 2>&1 || (echo ERROR: tar not found in PATH (Windows 10 1803+ required^) & exit /b 1)

for /f "tokens=3" %%v in ('go version') do echo          Go %%v
for /f "tokens=*" %%v in ('gcc --version 2^>^&1 ^| findstr /c:"gcc"') do echo          %%v

:: ----------------------------------------------------------
:: 2. Model sources (USER: edit these paths)
:: ----------------------------------------------------------
set MODEL_SRC=C:\workspace\models
set FP32_TAR=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09.tar
set PUNCT_TAR=sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar
set VAD_SRC=%MODEL_SRC%\silero_vad.onnx
set IOS_VAD=..\ios\VoiceNote\VoiceNote\Resources\VAD\silero_vad.onnx

if not exist "%MODEL_SRC%\%FP32_TAR%" (
    echo ERROR: %MODEL_SRC%\%FP32_TAR% not found
    exit /b 1
)
if not exist "%MODEL_SRC%\%PUNCT_TAR%" (
    echo ERROR: %MODEL_SRC%\%PUNCT_TAR% not found
    exit /b 1
)
echo          OK: Model sources found

:: ----------------------------------------------------------
:: 3. Extract & prepare models → internal/embedres/embed_models/
:: ----------------------------------------------------------
echo.
echo [2/7] Extracting models...

set EMBED_DIR=internal\embedres\embed_models
set TMP_EXTRACT=%TEMP%\voice_note_model_extract

:: Clean embed dir (keep .gitkeep)
if exist "%EMBED_DIR%" (
    for %%f in ("%EMBED_DIR%\*") do (
        if not "%%~nxf"==".gitkeep" del /q "%%f" 2>nul
    )
)

:: Clean temp extraction dir
if exist "%TMP_EXTRACT%" rmdir /s /q "%TMP_EXTRACT%" 2>nul
mkdir "%TMP_EXTRACT%"

:: Extract fp32 SenseVoice model
echo          Extracting FP32 SenseVoice model...
tar -xf "%MODEL_SRC%\%FP32_TAR%" -C "%TMP_EXTRACT%" >nul 2>&1
if errorlevel 1 (echo ERROR: tar extract failed for FP32 tar & exit /b 1)

:: Find the extracted directory
for /d %%d in ("%TMP_EXTRACT%\*") do set EXTRACT_DIR=%%d
if not defined EXTRACT_DIR (echo ERROR: Could not find extracted directory & exit /b 1)

:: Copy model.onnx and tokens.txt
copy /y "!EXTRACT_DIR!\model.onnx" "%EMBED_DIR%\model.onnx" >nul || (echo ERROR: model.onnx not found in tar & exit /b 1)
copy /y "!EXTRACT_DIR!\tokens.txt" "%EMBED_DIR%\tokens.txt" >nul || (echo ERROR: tokens.txt not found in tar & exit /b 1)
echo          Copied model.onnx and tokens.txt

:: Extract punctuation model
echo          Extracting punctuation model...
rmdir /s /q "%TMP_EXTRACT%" 2>nul
mkdir "%TMP_EXTRACT%"
tar -xf "%MODEL_SRC%\%PUNCT_TAR%" -C "%TMP_EXTRACT%" >nul 2>&1
if errorlevel 1 (echo ERROR: tar extract failed for punct tar & exit /b 1)

for /d %%d in ("%TMP_EXTRACT%\*") do set PUNCT_DIR=%%d
copy /y "!PUNCT_DIR!\model.onnx" "%EMBED_DIR%\punct_ct_transformer.onnx" >nul || (echo ERROR: punct model.onnx not found & exit /b 1)
echo          Copied punct_ct_transformer.onnx

:: Copy silero_vad.onnx (try model source first, then iOS resources)
if exist "%VAD_SRC%" (
    copy /y "%VAD_SRC%" "%EMBED_DIR%\silero_vad.onnx" >nul
) else if exist "%IOS_VAD%" (
    copy /y "%IOS_VAD%" "%EMBED_DIR%\silero_vad.onnx" >nul
) else (
    echo          WARNING: silero_vad.onnx not found - VAD will be disabled
)
if exist "%EMBED_DIR%\silero_vad.onnx" echo          Copied silero_vad.onnx

:: Cleanup
rmdir /s /q "%TMP_EXTRACT%" 2>nul

echo          Models prepared:
for %%f in ("%EMBED_DIR%\*") do echo            %%~nxf  (%%~zf bytes)

:: ----------------------------------------------------------
:: 4. Set build environment
:: ----------------------------------------------------------
echo.
echo [3/7] Setting build environment...

set CGO_ENABLED=1
set GOOS=windows
set GOARCH=amd64
set GOFLAGS=-buildvcs=false
:: Use China proxy for faster download (remove if not needed)
set GOPROXY=https://goproxy.cn,direct

echo          CGO_ENABLED=1  GOOS=windows  GOARCH=amd64

:: ----------------------------------------------------------
:: 5. Build main app with embedded models
:: ----------------------------------------------------------
echo.
echo [4/7] Building voice-note-desktop.exe (with embedded models)...
echo          This may take several minutes due to large model files (~1.2GB)...

set APP_EXE=voice-note-desktop.exe
if exist "%APP_EXE%" del /q "%APP_EXE%"

go build -tags embed -ldflags="-s -w -H windowsgui" -o "%APP_EXE%" .
if errorlevel 1 (
    echo ERROR: Build failed
    exit /b 1
)

for %%A in ("%APP_EXE%") do echo          %APP_EXE% built ^(size: %%~zA bytes^)

:: ----------------------------------------------------------
:: 6. Prepare launcher payload
:: ----------------------------------------------------------
echo.
echo [5/7] Preparing launcher payload...

set LAUNCHER_DIR=launcher
set PAYLOAD_DIR=%LAUNCHER_DIR%\payload

if exist "%PAYLOAD_DIR%" rmdir /s /q "%PAYLOAD_DIR%" 2>nul
mkdir "%PAYLOAD_DIR%"

:: Copy built app
copy /y "%APP_EXE%" "%PAYLOAD_DIR%\%APP_EXE%" >nul
echo          Copied %APP_EXE%

:: Copy sherpa-onnx DLLs from Go module cache
:: Find the mod cache: go env GOMODCACHE
for /f "tokens=*" %%p in ('go env GOMODCACHE') do set MODCACHE=%%p
set DLL_PATH=%MODCACHE%\github.com\k2-fsa\sherpa-onnx-go-windows@v1.13.6\lib\x86_64-pc-windows-gnu

if not exist "%DLL_PATH%" (
    echo ERROR: Sherpa-onnx DLLs not found at %DLL_PATH%
    echo        Run "go mod download" first?
    exit /b 1
)

:: Copy DLLs (only the ones linked at runtime)
for %%d in (onnxruntime.dll sherpa-onnx-c-api.dll sherpa-onnx-cxx-api.dll) do (
    if exist "%DLL_PATH%\%%d" (
        copy /y "%DLL_PATH%\%%d" "%PAYLOAD_DIR%\%%d" >nul
        echo          Copied %%d
    ) else (
        echo          WARNING: %%d not found
    )
)

:: ----------------------------------------------------------
:: 6. Build launcher (embeds payload/*)
:: ----------------------------------------------------------
echo.
echo [6/7] Building launcher.exe...

cd "%LAUNCHER_DIR%"

set LAUNCHER_EXE=voice-note.exe
if exist "%LAUNCHER_EXE%" del /q "%LAUNCHER_EXE%"

go build -ldflags="-s -w -H windowsgui" -o "%LAUNCHER_EXE%" .
if errorlevel 1 (
    cd ..
    echo ERROR: Launcher build failed
    exit /b 1
)

:: Move launcher to desktop/ root
move /y "%LAUNCHER_EXE%" "..\%LAUNCHER_EXE%" >nul
cd ..

:: Verify the final EXE
for %%A in ("%LAUNCHER_EXE%") do echo          %LAUNCHER_EXE% built ^(size: %%~zA bytes^)

:: ----------------------------------------------------------
:: 7. Cleanup
:: ----------------------------------------------------------
echo.
echo [7/7] Cleaning up...

:: Cleanup payload (already embedded in launcher)
rmdir /s /q "%PAYLOAD_DIR%" 2>nul

echo          Done.

:: ----------------------------------------------------------
:: Done
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   BUILD SUCCESSFUL
echo.
echo   Output: %CD%\%LAUNCHER_EXE%
echo.
echo   This single EXE contains:
echo     - Voice Note Desktop app (Fyne GUI)
echo     - FP32 SenseVoiceSmall model    (929 MB)
echo     - Punctuation model             (295 MB)
echo     - Silero VAD model              (0.6 MB)
echo     - sherpa-onnx DLLs              (22 MB)
echo.
echo   Double-click %LAUNCHER_EXE% to run.
echo   First launch extracts ~25 MB of DLLs to %%LOCALAPPDATA%%\VoiceNote\bin\
echo   and ~1.2 GB of models to %%APPDATA%%\VoiceNote\models\.
echo ============================================================