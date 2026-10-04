<#
    FPS Tweaker - tweak Windows biasa + tweak ala Atlas OS (versi skrip, tanpa install ulang Windows)

    Cara pakai : jalankan Run-FPSTweaker.bat (otomatis minta akses Administrator)
    Mode uji   : Run-FPSTweaker.bat -DryRun   (hanya menampilkan apa yang akan diubah, tidak mengubah apa pun)

    Semua nilai registry / service / scheduled task / power plan yang diubah dicatat dulu
    di backup\state.json, jadi bisa dikembalikan dengan tombol "Revert semua".
    Pengecualian: aplikasi bloatware yang sudah dihapus harus di-install ulang manual dari Microsoft Store.
#>
param([switch]$DryRun)

# ------------------------------------------------------------------ Elevate ke Admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($DryRun) { $argList += " -DryRun" }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList } catch { Write-Host "Butuh akses Administrator." }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$BackupDir = Join-Path $PSScriptRoot 'backup'
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
$StateFile = Join-Path $BackupDir 'state.json'
$LogFile   = Join-Path $BackupDir ("log-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:LogBox = $null

# ------------------------------------------------------------------ Utilitas
function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else { Write-Host $line }
}

function ConvertTo-HT($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HT $p.Value }
        return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return ,@($obj | ForEach-Object { ConvertTo-HT $_ })
    }
    return $obj
}

function Load-State {
    $s = $null
    if (Test-Path $StateFile) {
        try { $s = ConvertTo-HT (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch { $s = $null }
    }
    if ($s -isnot [hashtable]) { $s = @{} }
    foreach ($k in 'Registry', 'Services', 'Tasks') {
        if (-not $s.ContainsKey($k) -or $s[$k] -isnot [hashtable]) { $s[$k] = @{} }
    }
    return $s
}

function Save-State {
    if ($DryRun) { return }
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $StateFile -Encoding UTF8
}

$State = Load-State

# ------------------------------------------------------------------ Helper: Registry
function Backup-Reg([string]$Path, [string]$Name) {
    $key = "$Path|$Name"
    if ($State.Registry.ContainsKey($key)) { return }   # simpan nilai ASLI yang paling awal saja
    $entry = @{ Existed = $false; Type = $null; Value = $null }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if ($item.GetValueNames() -contains $Name) {
            $entry.Existed = $true
            $entry.Type    = $item.GetValueKind($Name).ToString()
            $entry.Value   = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    }
    $State.Registry[$key] = $entry
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    Backup-Reg $Path $Name
    if ($DryRun) { Log "  [dry] $Path\$Name = $Value"; return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch { Log "  ! gagal set $Path\$Name : $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ Helper: Service
function Disable-Svc([string]$Name) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $regPath)) { Log "  (skip) service $Name tidak ada"; return }
    if (-not $State.Services.ContainsKey($Name)) {
        $p = Get-ItemProperty -LiteralPath $regPath
        $State.Services[$Name] = @{ Start = [int]$p.Start; Delayed = [int]$p.DelayedAutostart }
    }
    if ($DryRun) { Log "  [dry] disable service $Name"; return }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    sc.exe config $Name start= disabled | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "  service $Name -> Disabled" } else { Log "  ! gagal disable service $Name (kode $LASTEXITCODE)" }
}

# ------------------------------------------------------------------ Helper: Scheduled Task
function Disable-Task([string]$TaskPath, [string]$TaskName) {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Log "  (skip) task $TaskName tidak ada"; return }
    $key = "$TaskPath|$TaskName"
    if (-not $State.Tasks.ContainsKey($key)) { $State.Tasks[$key] = ($t.State -ne 'Disabled') }
    if ($DryRun) { Log "  [dry] disable task $TaskPath$TaskName"; return }
    try {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Log "  task $TaskName -> Disabled"
    } catch { Log "  ! gagal disable task $TaskName : $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ Helper: Appx
function Remove-Bloat([string]$Name) {
    if ($DryRun) { Log "  [dry] hapus app $Name"; return }
    try {
        $pkgs = Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue
        foreach ($p in $pkgs) {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Log "  app dihapus: $($p.Name)"
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $Name } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
    } catch { Log "  ! gagal hapus $Name : $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ Restore point
function New-RestorePoint {
    if ($DryRun) { Log "[dry] buat restore point"; return $true }
    try {
        Log "Membuat restore point (bisa 1-2 menit)..."
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
            -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description ("FPS Tweaker {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) `
            -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log "Restore point berhasil dibuat."
        return $true
    } catch {
        Log "! Gagal membuat restore point: $($_.Exception.Message)"
        return $false
    }
}

# ================================================================== DAFTAR TWEAK
# Group : Basic   = tweak biasa, aman
#         Atlas   = tweak ala Atlas OS (debloat, telemetry, iklan, dll)
#         Extreme = berisiko, tidak pernah dipilih otomatis oleh preset
$Tweaks = @(
    # ---------------------------------------------------------- BASIC
    @{ Id='power'; Group='Basic'; Risk='Aman'; Name='Power plan Ultimate Performance'
       Desc='CPU tidak gampang turun clock saat main. Di laptop baterai jadi lebih boros.'
       Action={
           if (-not $State.ContainsKey('PowerScheme')) {
               $cur = (powercfg /getactivescheme) | Out-String
               if ($cur -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $State.PowerScheme = $Matches[1] }
           }
           if ($DryRun) { Log '  [dry] aktifkan Ultimate Performance'; return }
           $guid = $null
           if ($State.CreatedScheme -and (((powercfg /l) | Out-String) -match $State.CreatedScheme)) { $guid = $State.CreatedScheme }
           else {
               $out = (powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1) | Out-String
               if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                   $guid = $Matches[1]; $State.CreatedScheme = $guid
               }
           }
           if (-not $guid) { Log '  Ultimate tidak tersedia, pakai High Performance'; $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
           powercfg /setactive $guid 2>&1 | Out-Null
           if ($LASTEXITCODE -ne 0) {
               Log '  ! Power plan tidak bisa diaktifkan (biasanya laptop Modern Standby). Atur manual: Settings > Power > Power mode = Best performance.'
               return
           }
           Log "  power plan aktif: $guid"
       } }

    @{ Id='gamemode'; Group='Basic'; Risk='Aman'; Name='Game Mode ON'
       Desc='Windows memprioritaskan game dan menunda Windows Update saat main.'
       Action={
           Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
           Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
       } }

    @{ Id='hags'; Group='Basic'; Risk='Aman'; Name='Hardware-accelerated GPU scheduling ON'
       Desc='Mengurangi latency CPU->GPU. Butuh GPU dan driver yang mendukung (GTX 10xx / RX 5000 ke atas). Perlu restart.'
       Action={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 } }

    @{ Id='gamedvr'; Group='Basic'; Risk='Aman'; Name='Matikan Game DVR (rekaman background Xbox Game Bar)'
       Desc='Game Bar tidak merekam diam-diam di background. Fitur rekam Win+Alt+R jadi tidak aktif.'
       Action={
           Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
       } }

    @{ Id='mouse'; Group='Basic'; Risk='Aman'; Name='Matikan mouse acceleration'
       Desc='Gerakan mouse 1:1, aim lebih konsisten. Tidak menambah FPS, tapi terasa lebih responsif.'
       Action={
           Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
           Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
           Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
       } }

    @{ Id='visual'; Group='Basic'; Risk='Aman'; Name='Kurangi animasi dan transparansi'
       Desc='Matikan efek transparan, animasi minimize, Aero Peek, dan delay menu.'
       Action={
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
           Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
           Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
       } }

    @{ Id='bgapps'; Group='Basic'; Risk='Aman'; Name='Matikan background apps (aplikasi Store)'
       Desc='Aplikasi UWP/Store tidak jalan di background. Aplikasi desktop biasa tidak terpengaruh.'
       Action={
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
       } }

    @{ Id='mmcss'; Group='Basic'; Risk='Aman'; Name='Prioritas CPU/GPU untuk game (MMCSS + foreground boost)'
       Desc='Game di foreground dapat jatah CPU lebih besar. Throttling jaringan multimedia dimatikan.'
       Action={
           $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
           Set-Reg $mm 'SystemResponsiveness' 10
           Set-Reg $mm 'NetworkThrottlingIndex' 0xffffffff
           $g = "$mm\Tasks\Games"
           Set-Reg $g 'GPU Priority' 8
           Set-Reg $g 'Priority' 6
           Set-Reg $g 'Scheduling Category' 'High' 'String'
           Set-Reg $g 'SFIO Priority' 'High' 'String'
           Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
       } }

    @{ Id='startup'; Group='Basic'; Risk='Aman'; Name='Hilangkan delay aplikasi startup'
       Desc='Aplikasi startup langsung jalan setelah login, tidak ditahan sekitar 10 detik.'
       Action={ Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0 } }

    @{ Id='temp'; Group='Basic'; Risk='Aman'; Name='Bersihkan file temp'
       Desc='Hapus isi %TEMP% dan C:\Windows\Temp. File yang sedang dipakai otomatis dilewati.'
       Action={
           foreach ($d in @($env:TEMP, "$env:SystemRoot\Temp")) {
               if ($DryRun) { Log "  [dry] bersihkan $d"; continue }
               Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue |
                   Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
               Log "  dibersihkan: $d"
           }
       } }

    # ---------------------------------------------------------- ATLAS-LIKE
    @{ Id='telemetry'; Group='Atlas'; Risk='Sedang'; Name='Matikan telemetry dan tracking Microsoft'
       Desc='Matikan service DiagTrack, laporan error, dan scheduled task pengumpul data.'
       Action={
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
           Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
           Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
           foreach ($s in 'DiagTrack', 'dmwappushservice', 'WerSvc', 'diagnosticshub.standardcollector.service') { Disable-Svc $s }
           $tasks = @(
               @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
               @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
               @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
               @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
               @('\Microsoft\Windows\Autochk\', 'Proxy'),
               @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
               @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
               @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
               @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting')
           )
           foreach ($t in $tasks) { Disable-Task $t[0] $t[1] }
       } }

    @{ Id='ads'; Group='Atlas'; Risk='Sedang'; Name='Matikan iklan, saran, Bing search, Copilot, Widgets'
       Desc='Start menu dan search jadi bersih dan lokal saja. Activity history dan Advertising ID dimatikan.'
       Action={
           $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
           foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                          'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                          'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') { Set-Reg $cdm $v 0 }
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
           Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
           Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
           Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
           $sys = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
           Set-Reg $sys 'EnableActivityFeed' 0
           Set-Reg $sys 'PublishUserActivities' 0
           Set-Reg $sys 'UploadUserActivities' 0
       } }

    @{ Id='bloat'; Group='Atlas'; Risk='Sedang'; Name='Hapus bloatware (TIDAK bisa di-revert otomatis)'
       Desc='Hapus app bawaan seperti News, Weather, Solitaire, Clipchamp, Teams, Copilot, dll. Store, Xbox, Kalkulator, Foto, dan Notepad TIDAK dihapus.'
       Action={
           # Sengaja TIDAK dihapus (permintaan user): ZuneMusic, ZuneVideo, Microsoft3DViewer, 3DBuilder, QuickAssist
           $apps = 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp',
                   'Microsoft.Getstarted', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People',
                   'Microsoft.WindowsFeedbackHub',
                   'Microsoft.MicrosoftOfficeHub', 'Microsoft.SkypeApp', 'Clipchamp.Clipchamp',
                   'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'Microsoft.WindowsMaps',
                   'Microsoft.549981C3F5F10', 'Microsoft.Copilot', 'MicrosoftTeams', 'MSTeams',
                   'Microsoft.OutlookForWindows', 'Microsoft.MixedReality.Portal',
                   'Microsoft.WindowsAlarms', 'Microsoft.YourPhone',
                   'Microsoft.MicrosoftStickyNotes'
           foreach ($a in $apps) { Remove-Bloat $a }
       } }

    @{ Id='services'; Group='Atlas'; Risk='Sedang'; Name='Matikan service yang tidak penting'
       Desc='Maps, Retail Demo, Fax, Remote Registry, WMP Network, Insider, Parental Control, Link Tracking.'
       Action={
           foreach ($s in 'MapsBroker', 'RetailDemo', 'Fax', 'RemoteRegistry', 'WMPNetworkSvc',
                          'wisvc', 'WpcMonSvc', 'TrkWks') { Disable-Svc $s }
       } }

    @{ Id='throttle'; Group='Atlas'; Risk='Sedang'; Name='Matikan Power Throttling'
       Desc='Windows tidak menurunkan prioritas/clock proses yang jalan di background (misal game saat alt-tab). Di laptop baterai sedikit lebih boros.'
       Action={ Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 } }

    @{ Id='delivery'; Group='Atlas'; Risk='Aman'; Name='Matikan Delivery Optimization (P2P update)'
       Desc='PC tidak meng-upload update Windows ke PC lain lewat internet, jadi bandwidth tidak dipakai diam-diam.'
       Action={ Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 } }

    # ---------------------------------------------------------- HEMAT RAM
    @{ Id='browserbg'; Group='RAM'; Risk='Aman'; Name='Edge/Chrome tidak jalan di background'
       Desc='Edge Startup Boost dimatikan (Edge tidak dimuat diam-diam saat boot), dan Edge/Chrome benar-benar tertutup saat jendelanya ditutup. Di pengaturan Edge/Chrome akan muncul tulisan "Managed by your organization", itu normal.'
       Action={
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
           Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0
       } }

    @{ Id='svchost'; Group='RAM'; Risk='Sedang'; Name='Gabungkan proses svchost (jumlah proses berkurang)'
       Desc='Service Windows digabung ke lebih sedikit proses svchost.exe, jadi overhead RAM per proses berkurang. Kekurangan: kalau satu service crash, service lain di proses yang sama ikut terganggu. Perlu restart.'
       Action={
           $kb = [int][math]::Ceiling((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1KB)
           Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' $kb
       } }

    # ---------------------------------------------------------- EXTREME
    @{ Id='sysmain'; Group='Extreme'; Risk='Berisiko'; Name='Matikan SysMain dan Windows Search indexing'
       Desc='CPU dan disk lebih jarang sibuk. Tapi pencarian file/Start jadi lebih lambat, dan buka aplikasi di HDD bisa lebih lama.'
       Action={ Disable-Svc 'SysMain'; Disable-Svc 'WSearch' } }

    @{ Id='mitigations'; Group='Extreme'; Risk='Berisiko'; Name='Matikan mitigasi Spectre/Meltdown'
       Desc='Hanya terasa di CPU lama (Intel gen 4-9). Di CPU baru hampir tidak ada efek. Celah keamanan CPU jadi terbuka.'
       Action={
           $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
           Set-Reg $mm 'FeatureSettingsOverride' 3
           Set-Reg $mm 'FeatureSettingsOverrideMask' 3
       } }
)

# ================================================================== REVERT
function Invoke-RevertAll {
    if (-not (Test-Path $StateFile)) { Log 'Tidak ada backup. Belum ada tweak yang diterapkan.'; return }
    Log '=== REVERT dimulai ==='

    foreach ($key in @($State.Registry.Keys)) {
        $path, $name = $key -split '\|', 2
        $e = $State.Registry[$key]
        if ($DryRun) { Log "  [dry] restore $path\$name"; continue }
        try {
            if ($e.Existed) {
                $val = $e.Value
                switch ($e.Type) { 'Binary' { $val = [byte[]]$val } 'MultiString' { $val = [string[]]$val } }
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                New-ItemProperty -LiteralPath $path -Name $name -Value $val -PropertyType $e.Type -Force | Out-Null
            } elseif (Test-Path -LiteralPath $path) {
                Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue
            }
        } catch { Log "  ! gagal restore $path\$name : $($_.Exception.Message)" }
    }
    Log "  registry dikembalikan ($($State.Registry.Count) nilai)"

    $map = @{ 0 = 'boot'; 1 = 'system'; 2 = 'auto'; 3 = 'demand'; 4 = 'disabled' }
    foreach ($name in @($State.Services.Keys)) {
        $v = $State.Services[$name]
        $st = $map[[int]$v.Start]
        if ([int]$v.Start -eq 2 -and [int]$v.Delayed -eq 1) { $st = 'delayed-auto' }
        if ($DryRun) { Log "  [dry] service $name -> $st"; continue }
        sc.exe config $name start= $st | Out-Null
        Log "  service $name -> $st"
    }

    foreach ($key in @($State.Tasks.Keys)) {
        if (-not $State.Tasks[$key]) { continue }
        $tp, $tn = $key -split '\|', 2
        if ($DryRun) { Log "  [dry] enable task $tn"; continue }
        Enable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue | Out-Null
        Log "  task $tn -> Enabled"
    }

    if ($State.PowerScheme -and -not $DryRun) {
        powercfg /setactive $State.PowerScheme 2>&1 | Out-Null
        if ($State.CreatedScheme) { powercfg /delete $State.CreatedScheme 2>&1 | Out-Null }
        Log "  power plan dikembalikan ke $($State.PowerScheme)"
    }

    if (-not $DryRun) {
        Move-Item -Path $StateFile -Destination (Join-Path $BackupDir ("state-reverted-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
        $script:State = Load-State
    }
    Log '=== REVERT selesai. Silakan RESTART PC. (App bloatware yang terhapus install ulang dari Microsoft Store) ==='
}

# ================================================================== OPTIMIZE PC (RAM)
if (-not ([System.Management.Automation.PSTypeName]'FpsMemTools').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FpsMemTools {
    [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TokPriv { public int Count; public long Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokPriv newState, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static bool EnablePrivilege(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        TokPriv tp = new TokPriv(); tp.Count = 1; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, name, out tp.Luid)) { CloseHandle(tok); return false; }
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        CloseHandle(tok);
        return ok && err == 0;
    }

    // SystemMemoryListInformation = 80, MemoryPurgeStandbyList = 4. Return 0 = sukses.
    public static int PurgeStandbyList() {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        int cmd = 4;
        return NtSetSystemInformation(80, ref cmd, 4);
    }
}
'@
}

# Proses yang tidak boleh ditutup dari tab Optimize (penting untuk Windows / program ini sendiri)
$ProtectedProcs = @('System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso',
    'svchost', 'dwm', 'explorer', 'fontdrvhost', 'Memory Compression', 'MsMpEng', 'NisSrv', 'SecurityHealthService',
    'MpDefenderCoreService', 'SgrmBroker', 'sihost', 'ctfmon', 'audiodg', 'spoolsv', 'conhost', 'powershell',
    'RuntimeBroker', 'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost', 'TextInputHost', 'WmiPrvSE',
    'dllhost', 'taskhostw', 'vmmem', 'vmcompute', 'WUDFHost', 'LsaIso')

function Get-RamInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $free  = [double]$os.FreePhysicalMemory * 1KB
    [pscustomobject]@{ TotalGB = $total / 1GB; UsedGB = ($total - $free) / 1GB; Percent = [int](100 * ($total - $free) / $total) }
}

function Invoke-TrimRam {
    $before = Get-RamInfo
    if ($DryRun) { Log '[dry] trim working set semua proses'; return }
    Log 'Trim RAM semua proses...'
    $n = 0
    foreach ($p in Get-Process) {
        try { if ([FpsMemTools]::EmptyWorkingSet($p.Handle)) { $n++ } } catch { }
    }
    Start-Sleep -Milliseconds 700
    $after = Get-RamInfo
    Log ("Trim RAM selesai ({0} proses). Terpakai {1:N2} GB -> {2:N2} GB" -f $n, $before.UsedGB, $after.UsedGB)
}

function Invoke-PurgeStandby {
    if ($DryRun) { Log '[dry] kosongkan standby list'; return }
    $rc = [FpsMemTools]::PurgeStandbyList()
    if ($rc -eq 0) { Log 'Standby list (cache RAM) berhasil dikosongkan.' }
    else { Log ("! Gagal mengosongkan standby list (kode 0x{0:X8})" -f $rc) }
}

# ------------------------------------------------------------------ Startup apps
# Disable/Enable memakai mekanisme yang sama dengan tab Startup di Task Manager
# (registry StartupApproved), jadi entri aslinya tidak dihapus dan bisa di-enable lagi kapan saja.
function Test-StartupEnabled($item) {
    try {
        if (-not (Test-Path -LiteralPath $item.Approved)) { return $true }
        $k = Get-Item -LiteralPath $item.Approved
        if ($k.GetValueNames() -notcontains $item.ValueName) { return $true }
        $b = [byte[]]$k.GetValue($item.ValueName)
        if (-not $b -or $b.Length -eq 0) { return $true }
        return (($b[0] -band 1) -eq 0)
    } catch { return $true }
}

function Get-StartupItems {
    $base = 'Software\Microsoft\Windows\CurrentVersion'
    $appr = "$base\Explorer\StartupApproved"
    $list = New-Object System.Collections.ArrayList
    $regSources = @(
        @{ Run = "HKCU:\$base\Run"; Approved = "HKCU:\$appr\Run"; Loc = 'Registry (user)' },
        @{ Run = "HKLM:\$base\Run"; Approved = "HKLM:\$appr\Run"; Loc = 'Registry (semua user)' },
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$appr\Run32"; Loc = 'Registry (32-bit)' }
    )
    foreach ($s in $regSources) {
        if (-not (Test-Path -LiteralPath $s.Run)) { continue }
        $k = Get-Item -LiteralPath $s.Run
        foreach ($n in $k.GetValueNames()) {
            if ([string]::IsNullOrEmpty($n)) { continue }
            [void]$list.Add([pscustomobject]@{ Name = $n; ValueName = $n; Command = [string]$k.GetValue($n); Loc = $s.Loc; Approved = $s.Approved })
        }
    }
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$appr\StartupFolder"; Loc = 'Folder Startup (user)' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$appr\StartupFolder"; Loc = 'Folder Startup (semua user)' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            [void]$list.Add([pscustomobject]@{ Name = $_.BaseName; ValueName = $_.Name; Command = $_.FullName; Loc = $f.Loc; Approved = $f.Approved })
        }
    }
    foreach ($i in $list) { $i | Add-Member -NotePropertyName Enabled -NotePropertyValue (Test-StartupEnabled $i) }
    return $list
}

function Set-StartupState($item, [bool]$enable) {
    $label = $(if ($enable) { 'Enabled' } else { 'Disabled' })
    if ($DryRun) { Log "[dry] startup $($item.Name) -> $label"; return }
    try {
        if (-not (Test-Path -LiteralPath $item.Approved)) { New-Item -Path $item.Approved -Force | Out-Null }
        if ($enable) { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        else { $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes((Get-Date).ToFileTime())) }
        New-ItemProperty -LiteralPath $item.Approved -Name $item.ValueName -Value $bytes -PropertyType Binary -Force | Out-Null
        Log "Startup $($item.Name) -> $label"
    } catch { Log "! gagal ubah startup $($item.Name): $($_.Exception.Message)" }
}

# ================================================================== GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = 'FPS Tweaker' + $(if ($DryRun) { '  [DRY RUN - tidak mengubah apa pun]' } else { '' })
$form.Size = New-Object System.Drawing.Size(1000, 800)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$boldFont = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000

function New-Btn($parent, [string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 32)
    $parent.Controls.Add($b)
    return $b
}

function New-Lbl($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$bold = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    if ($bold) { $l.Font = $boldFont }
    $parent.Controls.Add($l)
    return $l
}

function New-LV($parent, [int]$x, [int]$y, [int]$w, [int]$h, $cols) {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.Location = New-Object System.Drawing.Point($x, $y)
    $lv.Size = New-Object System.Drawing.Size($w, $h)
    foreach ($c in $cols) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $parent.Controls.Add($lv)
    return $lv
}

[void](New-Lbl $form ("Tab Tweak: pilih tweak lalu klik APPLY (arahkan mouse ke opsi untuk lihat penjelasan). Semua perubahan bisa di-Revert.`r`n" +
    "Tab Optimize PC: pantau RAM, tutup proses berat, dan atur aplikasi startup.") 12 6 960 36)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 46)
$tabs.Size = New-Object System.Drawing.Size(600, 690)
$tabTweak = New-Object System.Windows.Forms.TabPage
$tabTweak.Text = 'Tweak'
$tabOpt = New-Object System.Windows.Forms.TabPage
$tabOpt.Text = 'Optimize PC (RAM)'
$tabs.TabPages.Add($tabTweak)
$tabs.TabPages.Add($tabOpt)
$form.Controls.Add($tabs)

# ------------------------------------------------------------------ Tab: Tweak
$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(6, 6)
$panel.Size = New-Object System.Drawing.Size(572, 604)
$panel.AutoScroll = $true
$panel.BorderStyle = 'FixedSingle'
$tabTweak.Controls.Add($panel)

$CheckBoxes = @{}
$groupTitles = [ordered]@{
    Basic   = 'TWEAK BIASA (aman)'
    Atlas   = 'TWEAK ALA ATLAS OS (debloat + privasi + performa)'
    RAM     = 'HEMAT RAM'
    Extreme = 'EXTREME (berisiko, pilih manual)'
}
$riskColor = @{
    Aman     = [System.Drawing.Color]::FromArgb(0, 120, 0)
    Sedang   = [System.Drawing.Color]::FromArgb(200, 110, 0)
    Berisiko = [System.Drawing.Color]::FromArgb(190, 0, 0)
}

$y = 8
foreach ($g in $groupTitles.Keys) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $groupTitles[$g]
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lbl.Location = New-Object System.Drawing.Point(8, $y)
    $lbl.AutoSize = $true
    $panel.Controls.Add($lbl)
    $y += 28
    foreach ($t in ($Tweaks | Where-Object { $_.Group -eq $g })) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "[{0}] {1}" -f $t.Risk, $t.Name
        $cb.ForeColor = $riskColor[$t.Risk]
        $cb.Location = New-Object System.Drawing.Point(16, $y)
        $cb.Size = New-Object System.Drawing.Size(520, 22)
        $tip.SetToolTip($cb, $t.Desc)
        $panel.Controls.Add($cb)
        $CheckBoxes[$t.Id] = $cb
        $y += 25
    }
    $y += 10
}

$btnBasic = New-Btn $tabTweak 'Preset: Basic' 6 618 110
$btnAtlas = New-Btn $tabTweak 'Preset: Atlas-like' 122 618 130
$btnClear = New-Btn $tabTweak 'Kosongkan' 258 618 90

$chkRestore = New-Object System.Windows.Forms.CheckBox
$chkRestore.Text = 'Buat restore point dulu'
$chkRestore.Checked = $true
$chkRestore.Location = New-Object System.Drawing.Point(362, 624)
$chkRestore.Size = New-Object System.Drawing.Size(200, 22)
$tabTweak.Controls.Add($chkRestore)

# ------------------------------------------------------------------ Tab: Optimize PC
$lblRam = New-Lbl $tabOpt 'RAM: ...' 8 8 570 22 $true
$pbRam = New-Object System.Windows.Forms.ProgressBar
$pbRam.Location = New-Object System.Drawing.Point(8, 34)
$pbRam.Size = New-Object System.Drawing.Size(570, 18)
$tabOpt.Controls.Add($pbRam)

[void](New-Lbl $tabOpt 'Proses pemakai RAM terbesar  (abu-abu = proses sistem, tidak bisa ditutup)' 8 62 570 20 $true)
$lvProc = New-LV $tabOpt 8 84 570 190 @(@('Nama proses', 300), @('RAM (MB)', 120), @('Jumlah', 100))
$btnProcRefresh = New-Btn $tabOpt 'Refresh' 8 280 100
$btnProcKill    = New-Btn $tabOpt 'Tutup proses terpilih' 114 280 170
$tip.SetToolTip($btnProcKill, 'Menutup paksa semua proses dengan nama itu. Simpan pekerjaanmu dulu, data yang belum disimpan bisa hilang.')

[void](New-Lbl $tabOpt 'Aplikasi startup  (sama seperti tab Startup di Task Manager)' 8 322 570 20 $true)
$lvStart = New-LV $tabOpt 8 344 570 170 @(@('Nama', 160), @('Status', 70), @('Lokasi', 150), @('Perintah', 420))
$btnStartDisable = New-Btn $tabOpt 'Disable startup' 8 520 150
$btnStartEnable  = New-Btn $tabOpt 'Enable startup' 164 520 150
$btnStartRefresh = New-Btn $tabOpt 'Refresh' 320 520 100
$tip.SetToolTip($btnStartDisable, 'Aplikasi tidak ikut jalan saat Windows menyala. Aplikasinya tidak dihapus, bisa di-Enable lagi kapan saja.')

[void](New-Lbl $tabOpt 'Pembersih RAM (efeknya sementara)' 8 562 570 20 $true)
$btnTrim    = New-Btn $tabOpt 'Trim RAM semua proses' 8 584 200
$btnStandby = New-Btn $tabOpt 'Kosongkan Standby List' 214 584 200
$tip.SetToolTip($btnTrim, 'Memaksa semua proses melepas RAM yang sedang tidak dipakai. Angka RAM turun, tapi aplikasi akan mengambilnya lagi saat dipakai (bisa sedikit lag sesaat).')
$tip.SetToolTip($btnStandby, 'Mengosongkan cache RAM (standby list). Kadang membantu mengurangi stutter di PC dengan RAM kecil, mirip tool ISLC.')
[void](New-Lbl $tabOpt ("Catatan: pembersih RAM cuma sementara, Windows akan memakai RAM lagi. Cara paling ampuh: disable aplikasi startup, " +
    "tutup aplikasi yang tidak dipakai, dan pakai grup HEMAT RAM di tab Tweak.") 8 622 570 36)

# ------------------------------------------------------------------ Log + tombol utama (kanan)
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:LogBox.Location = New-Object System.Drawing.Point(622, 68)
$script:LogBox.Size = New-Object System.Drawing.Size(356, 622)
$form.Controls.Add($script:LogBox)

$btnApply  = New-Btn $form 'APPLY TWEAK' 622 700 116
$btnRevert = New-Btn $form 'Revert semua' 742 700 114
$btnFolder = New-Btn $form 'Buka backup' 860 700 118
$btnApply.Font = $boldFont

# ------------------------------------------------------------------ Logic: Optimize
function Update-Ram {
    try {
        $r = Get-RamInfo
        $lblRam.Text = "RAM terpakai: {0:N1} GB dari {1:N1} GB ({2}%)" -f $r.UsedGB, $r.TotalGB, $r.Percent
        $pbRam.Value = [math]::Min(100, [math]::Max(0, $r.Percent))
    } catch { }
}

function Update-ProcList {
    $lvProc.BeginUpdate()
    $lvProc.Items.Clear()
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; MB = (($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB; Count = $_.Count }
    } | Sort-Object MB -Descending | Select-Object -First 30 | ForEach-Object {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$_.Name)
        [void]$it.SubItems.Add(("{0:N0}" -f $_.MB))
        [void]$it.SubItems.Add([string]$_.Count)
        if ($ProtectedProcs -contains $_.Name) { $it.ForeColor = [System.Drawing.Color]::Gray }
        [void]$lvProc.Items.Add($it)
    }
    $lvProc.EndUpdate()
}

function Update-StartupList {
    $lvStart.BeginUpdate()
    $lvStart.Items.Clear()
    foreach ($s in (Get-StartupItems | Sort-Object Name)) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$s.Name)
        [void]$it.SubItems.Add($(if ($s.Enabled) { 'Enabled' } else { 'Disabled' }))
        [void]$it.SubItems.Add([string]$s.Loc)
        [void]$it.SubItems.Add([string]$s.Command)
        if (-not $s.Enabled) { $it.ForeColor = [System.Drawing.Color]::Gray }
        $it.Tag = $s
        [void]$lvStart.Items.Add($it)
    }
    $lvStart.EndUpdate()
}

$btnProcRefresh.Add_Click({ Update-ProcList; Update-Ram })

$btnProcKill.Add_Click({
    $names = @($lvProc.SelectedItems | ForEach-Object { $_.Text })
    if ($names.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Pilih proses dulu di daftar.', 'FPS Tweaker') | Out-Null; return }
    $blocked = @($names | Where-Object { $ProtectedProcs -contains $_ })
    $names = @($names | Where-Object { $ProtectedProcs -notcontains $_ })
    if ($blocked.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("Proses sistem ini tidak boleh ditutup:`r`n$($blocked -join ', ')", 'FPS Tweaker', 'OK', 'Information') | Out-Null
    }
    if ($names.Count -eq 0) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("Tutup paksa proses ini?`r`n$($names -join ', ')`r`n`r`nData yang belum disimpan bisa hilang.", 'Konfirmasi', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    foreach ($n in $names) {
        if ($DryRun) { Log "[dry] tutup proses $n"; continue }
        Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Log "Proses ditutup: $n"
    }
    Start-Sleep -Milliseconds 500
    Update-ProcList; Update-Ram
})

$btnStartRefresh.Add_Click({ Update-StartupList })

$startToggle = {
    param([bool]$enable)
    $items = @($lvStart.SelectedItems | ForEach-Object { $_.Tag })
    if ($items.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Pilih aplikasi startup dulu di daftar.', 'FPS Tweaker') | Out-Null; return }
    foreach ($i in $items) { Set-StartupState $i $enable }
    Update-StartupList
}
$btnStartDisable.Add_Click({ & $startToggle $false })
$btnStartEnable.Add_Click({ & $startToggle $true })

$btnTrim.Add_Click({
    $form.Cursor = 'WaitCursor'
    try { Invoke-TrimRam; Update-Ram; Update-ProcList } finally { $form.Cursor = 'Default' }
})
$btnStandby.Add_Click({
    $form.Cursor = 'WaitCursor'
    try { Invoke-PurgeStandby; Update-Ram } finally { $form.Cursor = 'Default' }
})

$script:OptLoaded = $false
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabOpt -and -not $script:OptLoaded) {
        $script:OptLoaded = $true
        $form.Cursor = 'WaitCursor'
        try { Update-Ram; Update-ProcList; Update-StartupList } finally { $form.Cursor = 'Default' }
    }
})

$ramTimer = New-Object System.Windows.Forms.Timer
$ramTimer.Interval = 2000
$ramTimer.Add_Tick({ if ($tabs.SelectedTab -eq $tabOpt) { Update-Ram } })
$form.Add_Shown({ $ramTimer.Start() })
$form.Add_FormClosing({ $ramTimer.Stop() })

# ------------------------------------------------------------------ Logic: Tweak
function Set-Preset([string[]]$groups) {
    foreach ($t in $Tweaks) { $CheckBoxes[$t.Id].Checked = ($groups -contains $t.Group) }
}
$btnBasic.Add_Click({ Set-Preset @('Basic') })
$btnAtlas.Add_Click({ Set-Preset @('Basic', 'Atlas', 'RAM') })
$btnClear.Add_Click({ Set-Preset @() })
$btnFolder.Add_Click({ Start-Process explorer.exe $BackupDir })

function Set-Busy([bool]$busy) {
    foreach ($b in $btnBasic, $btnAtlas, $btnClear, $btnApply, $btnRevert) { $b.Enabled = -not $busy }
    $form.Cursor = $(if ($busy) { 'WaitCursor' } else { 'Default' })
}

$btnApply.Add_Click({
    $selected = @($Tweaks | Where-Object { $CheckBoxes[$_.Id].Checked })
    if ($selected.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Belum ada tweak yang dipilih di tab Tweak.', 'FPS Tweaker') | Out-Null; return }

    $risky = @($selected | Where-Object { $_.Risk -eq 'Berisiko' })
    if ($risky.Count -gt 0) {
        $names = ($risky | ForEach-Object { '- ' + $_.Name }) -join "`r`n"
        $r = [System.Windows.Forms.MessageBox]::Show("Kamu memilih tweak BERISIKO:`r`n$names`r`n`r`nLanjutkan?", 'Konfirmasi', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }

    Set-Busy $true
    try {
        if ($chkRestore.Checked) {
            if (-not (New-RestorePoint)) {
                $r = [System.Windows.Forms.MessageBox]::Show('Restore point gagal dibuat. Tetap lanjut? (Backup state.json tetap dibuat)', 'Peringatan', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return }
            }
        }
        foreach ($t in $selected) {
            Log "==> $($t.Name)"
            try { & $t.Action } catch { Log "  ! ERROR: $($_.Exception.Message)" }
            Save-State
        }
        Log '=== SELESAI. Restart PC supaya semua tweak aktif. ==='
        [System.Windows.Forms.MessageBox]::Show('Selesai! Restart PC supaya semua tweak aktif.', 'FPS Tweaker') | Out-Null
    } finally { Set-Busy $false }
})

$btnRevert.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show('Kembalikan SEMUA perubahan tweak yang pernah dibuat FPS Tweaker?', 'Revert', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Set-Busy $true
    try { Invoke-RevertAll } finally { Set-Busy $false }
})

Log ("FPS Tweaker siap. {0}" -f $(if ($DryRun) { 'MODE DRY RUN.' } else { '' }))
Log "Backup & log: $BackupDir"
if ($State.Registry.Count -gt 0) { Log "Ditemukan backup lama ($($State.Registry.Count) nilai registry). Revert tetap bisa dipakai." }

[void]$form.ShowDialog()
