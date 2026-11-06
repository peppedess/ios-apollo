@echo off
cd /d "%~dp0"
wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/Users/giuse/Desktop/ios-apollo/wsl/wlan-fw.sh > wsl\wlan-fw.txt 2>&1
echo fine> wsl\wlan-fw.done
