@echo off
REM WindsurfAPI one-click menu for Windows (counterpart of setup.sh).
REM Delegates to setup.ps1 - all logic and Chinese text live there so this
REM file stays pure ASCII (GBK-codepage-safe) like deploy/windows/*.bat.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
