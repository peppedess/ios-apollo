@echo off
cd /d "%~dp0.."
set "PATH=%USERPROFILE%\Desktop\Firmware e ROM\platform-tools;%PATH%"
del go\run.done 2>nul
(
echo === %date% %time%
adb reboot bootloader
fastboot boot img\apollo-next.img
echo boot rc=%errorlevel%
ping -n 25 127.0.0.1 >nul
echo === waiting for the phone to come back to fastboot, then recovery
fastboot reboot recovery
adb wait-for-recovery
echo === %date% %time%
adb shell "dd if=/dev/block/sda34 bs=4096 skip=59317242 count=1025 of=/tmp/sweetlog.bin && ls -l /tmp/sweetlog.bin"
adb pull /tmp/sweetlog.bin recon\sweetlog-k2.bin
echo rc=%errorlevel%
) > go\run.txt 2>&1
echo fine> go\run.done
