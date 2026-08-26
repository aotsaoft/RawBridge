@echo off
title RAW Bridge Receiver
cd /d %~dp0
echo =========================================
echo          RAW BRIDGE RECEIVER
echo =========================================
echo.
python -m pip install -r requirements.txt
if errorlevel 1 (
  echo Loi cai thu vien Python.
  pause
  exit /b 1
)
echo.
echo Server:
echo   http://100.120.33.35:8000
echo.
echo File nhan duoc nam tai:
echo   %~dp0RECEIVED
echo.
echo Nhan Ctrl+C de dung.
echo =========================================
python server.py
pause
