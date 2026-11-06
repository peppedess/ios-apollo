@echo off
cd /d "%~dp0"
set "PATH=%USERPROFILE%\Desktop\Firmware e ROM\platform-tools;%PATH%"
(adb devices & adb reboot bootloader & echo rc=%errorlevel%) > adb-bootloader.txt 2>&1
