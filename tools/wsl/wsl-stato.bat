@echo off
cd /d "%~dp0"
wsl -l -v > wsl-stato.txt 2>&1
wsl -d Ubuntu-24.04 -u root -- bash -c "uname -a; nproc; free -g; df -h /; whoami" >> wsl-stato.txt 2>&1
