@echo off
chcp 65001 >nul
setlocal
title Building FunASR Desktop Client

:: ============================================================
:: build.bat — Build funasr-desktop-client.exe for Windows
::
:: Output: dist\funasr-desktop-client.exe (portable, ~25 MB)
::
:: Prerequisites:
::   - Go 1.24+ (https://golang.google.cn/dl/)
::   - MinGW-w64 (for CGo)
::   - go-winres (go install github.com/tc-hib/go-winres@latest)
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
echo [1/4] Checking environment...

where go >nul 2>&1 || (echo ERROR: go not found in PATH & exit /b 1)
for /f "tokens=3" %%v in ('go version') do echo          Go %%v

where gcc >nul 2>&1 || (echo ERROR: gcc ^(MinGW-w64^) not found in PATH & exit /b 1)
for /f "tokens=*" %%v in ('gcc --version 2^>^&1 ^| findstr /c:"gcc"') do echo          %%v

if not exist "main.go" (echo ERROR: run this script from funasr_desktop\ directory & exit /b 1)
if not exist "go.mod" (echo ERROR: run this script from funasr_desktop\ directory & exit /b 1)

:: ----------------------------------------------------------
:: 2. Set build environment
:: ----------------------------------------------------------
echo.
echo [2/4] Setting build environment...

set CGO_ENABLED=1
set GOOS=windows
set GOARCH=amd64
set GOFLAGS=-buildvcs=false
set GOPROXY=https://goproxy.cn,direct

echo          CGO_ENABLED=1  GOOS=windows  GOARCH=amd64

:: ----------------------------------------------------------
:: 3. Embed Windows resources (icon + manifest)
:: ----------------------------------------------------------
echo.
echo [3/4] Embedding Windows resources...

where go-winres >nul 2>&1 || (
    echo          Installing go-winres...
    go install github.com/tc-hib/go-winres@latest
)

go-winres make --arch amd64
if errorlevel 1 (
    echo WARNING: go-winres failed, icon will be missing from .exe
)

:: ----------------------------------------------------------
:: 4. Build app
:: ----------------------------------------------------------
echo.
echo [4/4] Building funasr-desktop-client.exe...
echo          This may take a minute on first build (dependency download)...

if not exist "dist" mkdir dist

go build -trimpath -ldflags="-s -w -H windowsgui" -o "dist\funasr-desktop-client.exe" .
if errorlevel 1 (
    echo ERROR: Build failed
    exit /b 1
)

for %%A in ("dist\funasr-desktop-client.exe") do echo          %%~nxA built ^(size: %%~zA bytes^)

:: ----------------------------------------------------------
:: Done
:: ----------------------------------------------------------
echo.
echo ============================================================
echo   BUILD SUCCESSFUL
echo.
echo   Binary: %CD%\dist\funasr-desktop-client.exe
echo.
echo   Run it alongside a FunASR 2pass server (myfunasr_online).
echo ============================================================

endlocal