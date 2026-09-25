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
echo [1/8] Checking environment...

where go >nul 2>&1 || (echo ERROR: go not found in PATH & exit /b 1)
where gcc >nul 2>&1 || (echo ERROR: gcc - MinGW-w64 - not found in PATH & exit /b 1)
where powershell >nul 2>&1 || (echo ERROR: powershell not found in PATH & exit /b 1)
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
:: 3. Model sources
::    Default: %USERPROFILE%\.voicenote\models
::    Override with MODEL_SRC env var
:: ----------------------------------------------------------
if not defined MODEL_SRC set MODEL_SRC=%USERPROFILE%\.voicenote\models

echo          Model source: %MODEL_SRC%

set MODEL_FILES=model.onnx tokens.txt silero_vad.onnx punct_ct_transformer.onnx
for %%m in (%MODEL_FILES%) do (
    if not exist "%MODEL_SRC%\%%m" (
        echo ERROR: model file not found: %MODEL_SRC%\%%m
        echo   Download them to %USERPROFILE%\.voicenote\models\ first
        echo   or set MODEL_SRC to the directory containing model files.
        exit /b 1
    )
)
echo          OK: All model files found

:: ----------------------------------------------------------
:: 4. Copy models → dist/.../models/
:: ----------------------------------------------------------
echo.
echo [2/8] Copying models...

for %%m in (model.onnx tokens.txt silero_vad.onnx punct_ct_transformer.onnx) do (
    copy /y "%MODEL_SRC%\%%m" "%MODEL_DIST%\%%m" >nul
)

echo          Models prepared:
for %%f in ("%MODEL_DIST%\*") do echo            %%~nxf  (%%~zf bytes)

:: ----------------------------------------------------------
:: 5. Set build environment
:: ----------------------------------------------------------
echo.
echo [3/8] Setting build environment...

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
echo [4/8] Embedding Windows resources...

where go-winres >nul 2>&1 || (echo ERROR: go-winres not found - run: go install github.com/tc-hib/go-winres@latest & exit /b 1)

go-winres make --in winres/winres.json --out rsrc --arch amd64
if errorlevel 1 (echo ERROR: go-winres failed & exit /b 1)
echo          Generated rsrc_windows_amd64.syso

:: ----------------------------------------------------------
:: 7. Build app
:: ----------------------------------------------------------
echo.
echo [5/8] Building voice-note-desktop.exe...
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
echo [6/8] Copying to dist...

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
echo [7/8] Cleanup...

del /q "%APP_EXE%" 2>nul
del /q rsrc_windows_amd64.syso 2>nul

echo          Done.

:: ----------------------------------------------------------
:: 10. Package into tar (no compression)
:: ----------------------------------------------------------
echo.
echo [8/8] Creating tar package...

for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set TAR_NAME=voice-note-windows-amd64-%%d.tar
set TAR_PATH=dist\%TAR_NAME%

if exist "%TAR_PATH%" del /q "%TAR_PATH%" 2>nul
tar -cf "%TAR_PATH%" -C dist voice-note-windows-amd64
if errorlevel 1 (echo ERROR: tar package failed & exit /b 1)

for %%A in ("%TAR_PATH%") do echo          Package: %TAR_PATH% ^(size: %%~zA bytes^)

:: ----------------------------------------------------------
:: Done
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   BUILD SUCCESSFUL
echo.
echo   Output folder:  %CD%\%RELEASE_DIR%\
echo   Tar package:    %CD%\%TAR_PATH%
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
echo     1. Send %TAR_NAME%
echo     2. User extracts with: tar -xf %TAR_NAME%
echo     3. Double-click voice-note-desktop.exe to run
echo.
echo   Models are auto-detected from the adjacent models/ folder.
echo ============================================================