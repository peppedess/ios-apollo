@echo off
cd /d "%~dp0"
(
echo === %time% install
wsl --install -d Ubuntu-24.04 --no-launch
echo rc=%errorlevel%
echo === %time% list
wsl -l -v
echo === %time% first run as root
wsl -d Ubuntu-24.04 -u root -- bash -c "uname -a; nproc; free -g; df -h /; whoami"
echo rc=%errorlevel%
) > wsl-distro.txt 2>&1
echo fine> wsl-distro.done
