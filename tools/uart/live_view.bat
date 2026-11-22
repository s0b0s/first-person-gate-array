@echo off
rem Live picture of the game over the Cmod's USB-UART (tools/uart/live_view.py).
rem Double-click to start; close the viewer window to stop. Needs uv: https://docs.astral.sh/uv/
cd /d "%~dp0..\.."
uv run tools\uart\live_view.py
if errorlevel 1 pause
