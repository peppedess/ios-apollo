#!/bin/bash
# apollo: find the QCA6390 firmware (amss, m3, board data, regdb) in the vendor.img already pulled (EROFS) and in
# backup/modem.img (FAT), copy it to recon/wlan (out of git). Reads only local copies, never the phone.
D=/mnt/c/Users/giuse/Desktop/ios-apollo
cd /root
command -v fsck.erofs >/dev/null || apt-get install -y -qq erofs-utils >/dev/null
command -v mdir >/dev/null || apt-get install -y -qq mtools >/dev/null
if [ ! -d x-vendor/firmware ]; then
	rm -rf x-vendor; mkdir -p x-vendor
	fsck.erofs --extract=x-vendor "$D/recon/touch/vendor.img" >/dev/null 2>&1
fi
echo "== vendor"
find x-vendor \( -iname 'amss*' -o -iname 'm3*.bin' -o -iname 'bdwlan*' -o -iname 'regdb*' -o -iname 'Data.msc' -o -iname '*qca6390*' -o -iname 'wlan*.bin' \) -exec ls -la {} \; | head -60
echo "== vendor ini"
find x-vendor -iname 'WCNSS_qcom_cfg.ini' -exec ls -la {} \;
echo "== modem"
mdir -/ -b -i "$D/backup/modem.img" ::/ 2>/dev/null | grep -i -e amss -e 'm3\.' -e bdwlan -e regdb -e qca6390 | head -40
mkdir -p "$D/recon/wlan"
find x-vendor \( -iname 'amss*' -o -iname 'm3*.bin' -o -iname 'bdwlan*' -o -iname 'regdb*' -o -iname 'Data.msc' -o -iname 'WCNSS_qcom_cfg.ini' \) -exec cp -v {} "$D/recon/wlan/" \;
for f in $(mdir -/ -b -i "$D/backup/modem.img" ::/ 2>/dev/null | grep -i -e amss -e bdwlan -e regdb -e '/m3\.' -e '/bd_j3s'); do
	mcopy -n -o -i "$D/backup/modem.img" "$f" "$D/recon/wlan/modem-$(basename "$f")" 2>&1
done
ls -la "$D/recon/wlan"
sha256sum "$D"/recon/wlan/* 2>/dev/null
echo WLAN-FW-END
