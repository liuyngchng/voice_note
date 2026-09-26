@echo off
chcp 65001 >nul
setlocal
title Building FunASR Desktop Client

:: ============================================================
:: build.bat — Build funasr-desktop-client.exe for Windows
::
:: Output: funasr-desktop-client.exe (portable, ~50 MB)
::
:: Prerequisites:
::   - Go 1.24+ (https://golang.google.cn/dl/)
::
:: Mic capture uses WASAPI (pure Go) + Fyne OpenGL (CGo, needs MinGW-w64).
:: ============================================================

cd /d "%~dp0"
echo [BUILD] FunASR Desktop Client (Go + Fyne, Windows)
echo [BUILD] Working directory: %CD%

:: ----------------------------------------------------------
:: 1. Check prerequisites
:: ----------------------------------------------------------
echo.
echo [1/3] Checking environment...

where go >nul 2>&1 || (echo ERROR: go not found in PATH & exit /b 1)
for /f "tokens=3" %%v in ('go version') do echo          Go %%v

where gcc >nul 2>&1 || (echo ERROR: gcc ^(MinGW-w64^) not found in PATH & exit /b 1)
for /f "tokens=*" %%v in ('gcc --version 2^>^&1 ^| findstr /c:"gcc"') do echo          %%v

if not exist "main.go" (echo ERROR: run this script from fun_asr_desktop_client\ directory & exit /b 1)
if not exist "go.mod" (echo ERROR: run this script from fun_asr_desktop_client\ directory & exit /b 1)

:: ----------------------------------------------------------
:: 2. Set build environment
:: ----------------------------------------------------------
echo.
echo [2/3] Setting build environment...

set CGO_ENABLED=1
set GOOS=windows
set GOARCH=amd64
set GOFLAGS=-buildvcs=false
set GOPROXY=https://goproxy.cn,direct

echo          CGO_ENABLED=1  GOOS=windows  GOARCH=amd64

:: ----------------------------------------------------------
:: 3. Build app
:: ----------------------------------------------------------
echo.
echo [3/3] Building funasr-desktop-client.exe...
echo          This may take a minute on first build (dependency download)...

go build -trimpath -ldflags="-s -w -H windowsgui" -o "funasr-desktop-client.exe" .
if errorlevel 1 (
    echo ERROR: Build failed
    exit /b 1
)

for %%A in ("funasr-desktop-client.exe") do echo          %%~nxA built ^(size: %%~zA bytes^)

:: ----------------------------------------------------------
:: Done
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   BUILD SUCCESSFUL
echo.
echo   Binary: %CD%\funasr-desktop-client.exe
echo.
echo   Run it alongside a FunASR 2pass server (myfunasr_online).
echo ============================================================

endlocal