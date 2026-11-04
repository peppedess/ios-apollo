@echo off
cd /d "%~dp0"
wsl -d Ubuntu-24.04 -u root -- bash -c "sed -i 's/\r$//' /mnt/c/Users/giuse/Desktop/ios-apollo/wsl/apollo-wsl.sh; bash /mnt/c/Users/giuse/Desktop/ios-apollo/wsl/apollo-wsl.sh setup" > wsl-setup.log 2>&1
echo fine> wsl-setup.done
