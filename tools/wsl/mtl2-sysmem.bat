@echo off
cd /d "%~dp0"
wsl -d Ubuntu-24.04 -u root -- bash -c "sed -i 's/\r$//' /mnt/c/Users/giuse/Desktop/ios-apollo/wsl/mtl2-env.sh; bash /mnt/c/Users/giuse/Desktop/ios-apollo/wsl/mtl2-env.sh TU_DEBUG=sysmem" > mtl2-env.log 2>&1
echo fine> mtl2-env.done
