@echo off
setlocal

cd /d "%~dp0" || exit /b 1

where reapack-index >nul 2>&1
if errorlevel 1 (
    echo ERROR: reapack-index was not found on PATH.
    echo Install Ruby, then run: gem install reapack-index
    exit /b 1
)

reapack-index --name "Randall Dibiasky Scripts"
set "result=%ERRORLEVEL%"
if not "%result%"=="0" (
    echo ERROR: reapack-index failed with exit code %result%.
    exit /b %result%
)

echo Updated index.xml.
exit /b 0
