@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Building Voice Note Desktop

:: ============================================================
:: build.bat - Build Voice Note Desktop (portable ZIP layout)
::
:: Output: dist/voice-note-windows-amd64/
::   voice-note-desktop.exe       (app, ~50 MB)
::   onnxruntime.dll              (included)
::   sherpa-onnx-c-api.dll        (included)
::   sherpa-onnx-cxx-api.dll      (included)
::   models/                      (model files)
::     model.onnx                 (~930 MB)
::     tokens.txt
::     punct_ct_transformer.onnx  (~295 MB)
::     silero_vad.onnx            (~0.6 MB)
::
:: User zips the dist folder and distributes.
:: ============================================================

cd /d "%~dp0"
echo [BUILD] Voice Note Desktop (portable layout)
echo [BUILD] Working directory: %CD%

:: ----------------------------------------------------------
:: 1. Check prerequisites
:: ----------------------------------------------------------
echo.
echo [1/7] Checking environment...

where go >nul 2>&1 || (echo ERROR: go not found in PATH & exit /b 1)
where gcc >nul 2>&1 || (echo ERROR: gcc - MinGW-w64 - not found in PATH & exit /b 1)
where tar >nul 2>&1 || (echo ERROR: tar not found in PATH - Windows 10 1803 or newer required & exit /b 1)

for /f "tokens=3" %%v in ('go version') do echo          Go %%v
for /f "tokens=*" %%v in ('gcc --version 2^>^&1 ^| findstr /c:"gcc"') do echo          %%v

:: ----------------------------------------------------------
:: 2. Prepare output directory
:: ----------------------------------------------------------
set RELEASE_DIR=dist\voice-note-windows-amd64
set MODEL_DIST=%RELEASE_DIR%\models

if exist "%RELEASE_DIR%" rmdir /s /q "%RELEASE_DIR%" 2>nul
mkdir "%RELEASE_DIR%"
mkdir "%MODEL_DIST%"
echo          Output: %RELEASE_DIR%

:: ----------------------------------------------------------
:: 3. Model sources (USER: edit these paths)
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
:: 4. Extract & copy models → dist/.../models/
:: ----------------------------------------------------------
echo.
echo [2/7] Extracting models...

set TMP_EXTRACT=%TEMP%\voice_note_model_extract
if exist "%TMP_EXTRACT%" rmdir /s /q "%TMP_EXTRACT%" 2>nul
mkdir "%TMP_EXTRACT%"

:: Extract fp32 SenseVoice model
echo          Extracting FP32 SenseVoice model...
tar -xf "%MODEL_SRC%\%FP32_TAR%" -C "%TMP_EXTRACT%" >nul 2>&1
if errorlevel 1 (echo ERROR: tar extract failed for FP32 tar & exit /b 1)

for /d %%d in ("%TMP_EXTRACT%\*") do set EXTRACT_DIR=%%d
if not defined EXTRACT_DIR (echo ERROR: Could not find extracted directory & exit /b 1)

copy /y "!EXTRACT_DIR!\model.onnx" "%MODEL_DIST%\model.onnx" >nul || (echo ERROR: model.onnx not found in tar & exit /b 1)
copy /y "!EXTRACT_DIR!\tokens.txt" "%MODEL_DIST%\tokens.txt" >nul || (echo ERROR: tokens.txt not found in tar & exit /b 1)
echo          Copied model.onnx and tokens.txt

:: Extract punctuation model
echo          Extracting punctuation model...
rmdir /s /q "%TMP_EXTRACT%" 2>nul
mkdir "%TMP_EXTRACT%"
tar -xf "%MODEL_SRC%\%PUNCT_TAR%" -C "%TMP_EXTRACT%" >nul 2>&1
if errorlevel 1 (echo ERROR: tar extract failed for punct tar & exit /b 1)

for /d %%d in ("%TMP_EXTRACT%\*") do set PUNCT_DIR=%%d
copy /y "!PUNCT_DIR!\model.onnx" "%MODEL_DIST%\punct_ct_transformer.onnx" >nul || (echo ERROR: punct model.onnx not found & exit /b 1)
echo          Copied punct_ct_transformer.onnx

:: Copy silero_vad.onnx
if exist "%VAD_SRC%" (
    copy /y "%VAD_SRC%" "%MODEL_DIST%\silero_vad.onnx" >nul
) else if exist "%IOS_VAD%" (
    copy /y "%IOS_VAD%" "%MODEL_DIST%\silero_vad.onnx" >nul
) else (
    echo          WARNING: silero_vad.onnx not found - VAD will be disabled
)
if exist "%MODEL_DIST%\silero_vad.onnx" echo          Copied silero_vad.onnx

rmdir /s /q "%TMP_EXTRACT%" 2>nul

echo          Models prepared:
for %%f in ("%MODEL_DIST%\*") do echo            %%~nxf  (%%~zf bytes)

:: ----------------------------------------------------------
:: 5. Set build environment
:: ----------------------------------------------------------
echo.
echo [3/7] Setting build environment...

set CGO_ENABLED=1
set GOOS=windows
set GOARCH=amd64
set GOFLAGS=-buildvcs=false
set GOPROXY=https://goproxy.cn,direct

echo          CGO_ENABLED=1  GOOS=windows  GOARCH=amd64

:: ----------------------------------------------------------
:: 6. Embed Windows resources (icon, version info, manifest)
:: ----------------------------------------------------------
echo.
echo [4/7] Embedding Windows resources...

where go-winres >nul 2>&1 || (echo ERROR: go-winres not found - run: go install github.com/tc-hib/go-winres@latest & exit /b 1)

go-winres make --in winres/winres.json --out rsrc --arch amd64
if errorlevel 1 (echo ERROR: go-winres failed & exit /b 1)
echo          Generated rsrc_windows_amd64.syso

:: ----------------------------------------------------------
:: 7. Build app
:: ----------------------------------------------------------
echo.
echo [5/7] Building voice-note-desktop.exe...
echo          This may take several minutes due to CGo linking...

set APP_EXE=voice-note-desktop.exe
go build -ldflags="-s -w -H windowsgui" -o "%APP_EXE%" .
if errorlevel 1 (
    echo ERROR: Build failed
    exit /b 1
)

for %%A in ("%APP_EXE%") do echo          %APP_EXE% built ^(size: %%~zA bytes^)

:: ----------------------------------------------------------
:: 8. Copy build artifacts to dist/
:: ----------------------------------------------------------
echo.
echo [6/7] Copying to dist...

copy /y "%APP_EXE%" "%RELEASE_DIR%\%APP_EXE%" >nul
echo          Copied %APP_EXE%

:: Copy sherpa-onnx DLLs
for /f "tokens=*" %%p in ('go env GOMODCACHE') do set MODCACHE=%%p
set DLL_PATH=%MODCACHE%\github.com\k2-fsa\sherpa-onnx-go-windows@v1.13.6\lib\x86_64-pc-windows-gnu

if not exist "%DLL_PATH%" (
    echo ERROR: Sherpa-onnx DLLs not found at %DLL_PATH%
    echo        Run "go mod download" first?
    exit /b 1
)

for %%d in (onnxruntime.dll sherpa-onnx-c-api.dll sherpa-onnx-cxx-api.dll) do (
    if exist "%DLL_PATH%\%%d" (
        copy /y "%DLL_PATH%\%%d" "%RELEASE_DIR%\%%d" >nul
        echo          Copied %%d
    ) else (
        echo          WARNING: %%d not found
    )
)

:: ----------------------------------------------------------
:: 9. Cleanup
:: ----------------------------------------------------------
echo.
echo [7/7] Cleanup...

del /q "%APP_EXE%" 2>nul
del /q rsrc_windows_amd64.syso 2>nul

echo          Done.

:: ----------------------------------------------------------
:: Done
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   BUILD SUCCESSFUL
echo.
echo   Output: %CD%\%RELEASE_DIR%\
echo.
echo   Contents:
echo     voice-note-desktop.exe       (portable app)
echo     onnxruntime.dll
echo     sherpa-onnx-c-api.dll
echo     sherpa-onnx-cxx-api.dll
echo     models\
echo       model.onnx                 (SenseVoiceSmall FP32)
echo       tokens.txt
echo       punct_ct_transformer.onnx   (punctuation)
echo       silero_vad.onnx             (VAD)
echo.
echo   To distribute:
echo     1. Zip the %RELEASE_DIR% folder
echo     2. User unzips and runs voice-note-desktop.exe
echo     3. Double-click to run - no installation needed
echo.
echo   Models are auto-detected from the adjacent models/ folder.
echo ============================================================