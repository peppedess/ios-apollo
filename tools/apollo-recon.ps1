# Ricognizione dello Xiaomi 10T Pro (apollo, SM8250 "kona") per il port di iOS (base: ios-redfin).
# Adattato da tools/redfin-recon.ps1 e tools/redfin-backup.ps1 di DenialOfGravity/ios-redfin.
# Tutto in SOLA LETTURA sul telefono: niente viene scritto nella sua memoria.
#
#   powershell -ExecutionPolicy Bypass -File tools\apollo-recon.ps1 android   # Android avviato, debug USB attivo
#   powershell -ExecutionPolicy Bypass -File tools\apollo-recon.ps1 twrp      # telefono in TWRP (adb root)
#   powershell -ExecutionPolicy Bypass -File tools\apollo-recon.ps1 backup    # telefono in TWRP: copia tutte le partizioni
#
# Output: recon\ e backup\ nella cartella del progetto (ignorati da git). NON metterli su git: contengono seriale, IMEI e calibrazioni.
param([Parameter(Mandatory = $true)][ValidateSet("android", "twrp", "backup")][string]$Mode)
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")
$O = "recon"; New-Item -ItemType Directory -Force -Path $O, "$O\fw" | Out-Null

function Adb-Sh([string]$cmd) { (& adb shell $cmd 2>&1 | Out-String).Replace("`r", "") }
function Save([string]$name, [string]$cmd) { Adb-Sh $cmd | Out-File (Join-Path $O $name) -Encoding ascii }

if ($Mode -eq "android") {
	& adb wait-for-device
	Save "getprop.txt" "getprop"
	Save "cmdline-android.txt" "cat /proc/cmdline"
	$keys = "ro.product.device", "ro.product.model", "ro.build.fingerprint", "ro.build.version.incremental",
		"ro.bootloader", "ro.boot.hwc", "ro.boot.flash.locked", "ro.boot.verifiedbootstate",
		"ro.boot.slot_suffix", "ro.boot.dynamic_partitions", "ro.product.first_api_level"
	$lines = $(foreach ($k in $keys) { "{0,-34} {1}" -f $k, (Adb-Sh "getprop $k").Trim() })
	$lines | Tee-Object -FilePath (Join-Path $O "summary-android.txt")
	Write-Host "Fatto. Ora: adb reboot bootloader, avvia TWRP e lancia la modalita' twrp."
	exit 0
}

& adb wait-for-recovery
if ((Adb-Sh "id") -notmatch "uid=0") { Write-Error "adb non e' root: avvia prima TWRP"; exit 1 }
$model = (Adb-Sh "getprop ro.product.device").Trim()
Write-Host "dispositivo: $model"
if ($model -notmatch "apollo") { Write-Warning "non sembra uno Xiaomi 10T Pro (apollo): mi fermo"; exit 1 }

if ($Mode -eq "backup") {
	$ErrorActionPreference = "Stop"
	$B = "backup"; New-Item -ItemType Directory -Force -Path $B | Out-Null
	# userdata = dati Android, super = system/vendor (ripristinabili dalla ROM fastboot di Xiaomi)
	$skip = @("userdata", "super")
	$names = (Adb-Sh "ls /dev/block/by-name/").Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
	$memLine = (Adb-Sh "cat /proc/meminfo").Split("`n") | Where-Object { $_ -match '^MemAvailable:\s+(\d+)' } | Select-Object -First 1
	$free = 0
	if ($memLine -match '^MemAvailable:\s+(\d+)') { $free = [int64]$Matches[1] * 1024 }
	Write-Host ("RAM libera in TWRP: {0:N0} byte" -f $free)
	if ($free -lt 512MB) { throw "RAM libera di TWRP non leggibile ($free): mi fermo" }
	$log = Join-Path $B "backup-log.txt"
	"apollo backup $(Get-Date -Format s)" | Out-File $log -Encoding ascii
	foreach ($n in $names) {
		if ($skip -contains $n -or $n -match '^sd[a-z]$') { Write-Host "salto  $n"; continue }
		$dev = (Adb-Sh "readlink -f /dev/block/by-name/$n").Trim()
		$size = [int64](Adb-Sh "blockdev --getsize64 $dev").Trim()
		if ($size -gt ($free / 2)) { Write-Warning "salto  $n ($size byte, troppo grande per /tmp)"; "SALTATA $n $size" | Add-Content $log; continue }
		$dst = Join-Path $B "$n.img"
		if (Test-Path $dst) { Write-Host "c'e'   $n"; continue }
		Write-Host ("copio  {0,-24} {1,12:N0} byte" -f $n, $size)
		Adb-Sh "dd if=$dev of=/tmp/bk.img bs=1048576 2>/dev/null" | Out-Null
		$phoneSum = (Adb-Sh "sha256sum /tmp/bk.img").Trim().Split(" ")[0]
		& adb pull /tmp/bk.img $dst | Out-Null
		Adb-Sh "rm -f /tmp/bk.img" | Out-Null
		$pcSum = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
		if ($pcSum -ne $phoneSum) { Remove-Item $dst; throw "hash diverso su $n" }
		"$pcSum  $n.img  $size" | Add-Content $log
	}
	Write-Host "Backup finito: $B\ ($((Get-ChildItem $B -Filter *.img).Count) partizioni). Hash in $log"
	Write-Host "Copia backup\ anche fuori dal PC (chiavetta o cloud privato): persist, modemst1/2, fsg, fsc contengono IMEI e calibrazioni."
	exit 0
}

# --- modalita' twrp: fatti hardware per lo shim, il device tree Apple e i driver ---
# Device tree vivo, cosi' come ABL lo passa al kernel (dtb + overlay dtbo + correzioni di ABL)
& adb pull /sys/firmware/fdt "$O\live.dtb" | Out-Null
Save "iomem.txt" "cat /proc/iomem"
Save "cmdline-twrp.txt" "cat /proc/cmdline"
Save "by-name.txt" "ls -l /dev/block/by-name/"
# (niente virgolette doppie nei comandi adb shell: PowerShell 5 le rovina)
Save "partitions.txt" 'for d in /sys/block/sd*/sd*; do echo ${d##*/} start=$(cat $d/start) size=$(cat $d/size) $(grep PARTNAME $d/uevent); done; for d in /sys/block/sd?; do echo ${d##*/} lbs=$(cat $d/queue/logical_block_size); done'
Save "memory-reg.txt" 'for f in /proc/device-tree/memory*/reg; do echo $f; od -An -tx4 -v $f; done'
# Indirizzo e dimensione di ogni regione riservata (splash, smem, cmd-db, modem, wlan, gpu...)
Save "reserved-memory.txt" 'for d in /proc/device-tree/reserved-memory/*/; do n=${d%/}; echo ${n##*/}; [ -f $d/reg ] && od -An -tx4 -v $d/reg; done'
Save "model.txt" 'cat /proc/device-tree/model; echo; od -An -tx4 /proc/device-tree/qcom,msm-id; od -An -tx4 /proc/device-tree/qcom,board-id'
# Pannello, touch e tasti: cosa ha scelto davvero ABL
Save "panel.txt" 'for w in $(cat /proc/cmdline); do case $w in *mdss*|*dsi*|*panel*) echo $w;; esac; done; find /proc/device-tree -name qcom,mdss-dsi-panel-name 2>/dev/null | while read f; do echo $f; cat $f; echo; done | head -60'
Save "touch.txt" 'find /proc/device-tree -name compatible 2>/dev/null | while read f; do c=$(cat $f 2>/dev/null); case $c in *ts*|*touch*|*fts*|*goodix*|*novatek*|*focal*) echo ${f%/compatible} : $c;; esac; done'
Save "dmesg-twrp.txt" "dmesg"
Save "lsmod.txt" "cat /proc/modules"

# Firmware: GPU (Adreno 650) e Wi-Fi (QCA6390 su PCIe su kona) da vendor; il modem dalla sua partizione.
# apollo non e' A/B: lo slot di solito e' vuoto. Tutto montato in sola lettura.
$slot = (Adb-Sh "getprop ro.boot.slot_suffix").Trim()
Adb-Sh "mkdir -p /tmp/rv /tmp/rm; mount -o ro /dev/block/mapper/vendor$slot /tmp/rv 2>&1 || mount -o ro /vendor 2>&1; mount -t vfat -o ro /dev/block/by-name/modem$slot /tmp/rm 2>&1" | Out-File "$O\mounts.txt" -Encoding ascii
Save "vendor-firmware.txt" "ls -lR /tmp/rv/firmware /vendor/firmware 2>/dev/null"
Save "modem-firmware.txt" "ls -lR /tmp/rm/image 2>/dev/null | head -400"
foreach ($f in (Adb-Sh "cd /tmp/rv/firmware 2>/dev/null || cd /vendor/firmware; ls a6*_gmu.bin a6*_sqe.fw a650_zap.* 2>/dev/null").Split("`n")) {
	$f = $f.Trim(); if ($f) { & adb pull "/tmp/rv/firmware/$f" "$O\fw\$f" 2>$null | Out-Null; if (-not (Test-Path "$O\fw\$f")) { & adb pull "/vendor/firmware/$f" "$O\fw\$f" | Out-Null } }
}
Adb-Sh "umount /tmp/rm; umount /tmp/rv" | Out-Null

Write-Host ""
Get-Content "$O\model.txt"
Get-Content "$O\partitions.txt" | Select-String "userdata"
Get-Content "$O\memory-reg.txt"
Get-Content "$O\reserved-memory.txt" | Select-String -Context 0, 1 "splash"
Get-Content "$O\panel.txt"
Write-Host "Firmware GPU in $O\fw\:"; Get-ChildItem "$O\fw" | Format-Table Name, Length -AutoSize
Write-Host "Fatto. Mandami la cartella recon\ (senza backup\)."
