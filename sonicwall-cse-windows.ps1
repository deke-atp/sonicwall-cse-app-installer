# Run as administrator

################################################################################
# SonicWall Cloud Secure Edge Zero Touch Installation / Upgrade / Version True-Up
#
# Usage:
#   .\sonicwall-cse-windows.ps1 <INVITE_CODE> <DEPLOYMENT_KEY> [APP_VERSION]   zero-touch install
#   .\sonicwall-cse-windows.ps1 upgrade upgrade [APP_VERSION]                  upgrade / true-up
#
# Background: desktop app 4.0.0 renamed the executables, services, directories and
# installer identity. The 4.x EXE installer only removes a 3.x install that lives in
# "Program Files\Banyan", so devices that auto-updated from 3.x can end up with Banyan 3.x
# and SonicWall CSE 4.x installed side by side, with two sets of services fighting over
# the tunnel. Both flows below therefore inventory every Banyan/CSE install on the device,
# remove anything that is not the single target install, and only then install the target
# version. Running the script on a device that is already clean and at the target version
# is a no-op, so it is safe to run across a whole fleet.
#
# Confirm or update the following variables prior to running the script
################################################################################

# Deployment Information
# Obtain from the SonicWall Cloud Secure Edge admin console: Settings > CSE Client > Deployment
$INVITE_CODE = $args[0]
$DEPLOYMENT_KEY = $args[1]
$APP_VERSION = $args[2]

# Device Registration and SonicWall Cloud Secure Edge App Configuration
# Check docs for more options and details:
# https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/distribute-desktopapp/#mdm-config-json
$DEVICE_OWNERSHIP = "S"
$CA_CERTS_PREINSTALLED = $false
$SKIP_CERT_SUPPRESSION = $false
$IS_MANAGED_DEVICE = $false
$DEVICE_MANAGER_NAME = ""
$HIDE_SERVICES = $false
$DISABLE_QUIT = $false
$START_AT_BOOT = $true
$AUTO_LOGIN = $false
$HIDE_ON_START = $true
$DISABLE_AUTO_UPDATE = $false
$ALLOW_MULTIORG = $false
$ST_OVER_443 = $false

# User Information for Device Certificate
$MULTI_USER = $true

# Preview Feature: Allow App via NetFirewallRule for Windows Firewall.
$ALLOW_APP = $false

# Installer type: "msi" or "exe"
# SonicWall recommends the MSI for managed Windows devices on 4.3.0 and later. The MSI performs
# in-place upgrades and is eligible for auto-update. The script falls back to the EXE automatically
# for target versions earlier than 4.3.0.
$INSTALLER_TYPE = "msi"

# Remove legacy Banyan 3.x installs, and any 4.x install that does not match the target
# installer type and version, before installing.
$REMOVE_LEGACY = $true

# Reinstall even when the device is already clean and at the target version.
$FORCE_REINSTALL = $false

# Require a valid SonicWall Authenticode signature on the downloaded installer.
$VERIFY_SIGNATURE = $true

# Report what would be removed and installed, then exit without changing anything.
$DRY_RUN = $false


################################################################################

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg) }
function Fail($msg) { Write-Host "ERROR: $msg"; exit 1 }

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (! $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "This script must be run with admin privilege"
}

if (!$INVITE_CODE -or !$DEPLOYMENT_KEY) {
    Write-Host "Usage: "
    Write-Host "$PSCommandPath <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional)>"
    Write-Host "$PSCommandPath upgrade upgrade <APP_VERSION (optional)>"
    exit 1
}

$UPGRADE_FLOW = (($INVITE_CODE -eq "upgrade") -and ($DEPLOYMENT_KEY -eq "upgrade"))

# Well-known names and identifiers
$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$CSE_INSTALL_DIR = Join-Path $ProgramFiles64 "SonicWall Cloud Secure Edge"
$CSE_EXE = Join-Path $CSE_INSTALL_DIR "SonicWall Cloud Secure Edge.exe"
$CSE_BIN_DIR = Join-Path $CSE_INSTALL_DIR "resources\bin"
$global_profile_dir = "C:\ProgramData"
$CSE_CONFIG_DIR = Join-Path $global_profile_dir "SonicWallCSE"
$CSE_CONFIG_FILE = Join-Path $CSE_CONFIG_DIR "mdm-config.json"
$LEGACY_CONFIG_FILES = @((Join-Path $global_profile_dir "CSE\mdm-config.json"), (Join-Path $global_profile_dir "banyanapp\mdm-config.json"))
$CSE_VERSION_REG_KEY = "HKLM:\SOFTWARE\SonicWall\CloudSecureEdge"
$CSE_EXE_GUID = "4d8a012d-c95e-5593-8a34-2f8eac9d19dd"      # electron-builder app GUID for com.sonicwall.cse (4.x EXE)
$LEGACY_EXE_GUID = "801388f2-a9e0-5ca9-a9e7-de7a5cb4e1c2"   # electron-builder app GUID for com.banyan.app (3.x EXE)
$LEGACY_SERVICES = @("banyanapp-admin", "banyan-wgs")
$CSE_SERVICES = @("sonicwall-cse-admin", "sonicwall-cse-wgs", "sonicwall-cse-updater")
$GUI_PROCESSES = @("Banyan", "SonicWall Cloud Secure Edge", "sonicwall-cse-launcher")
$LEGACY_PROCESSES = @("banyanapp-admin", "banyan-wgs", "banyanproxy")

$tmp_dir = Join-Path $global_profile_dir "sonicwallcsetemp"
New-Item -Path $tmp_dir -ItemType "directory" -Force | Out-Null


################################################################################
# Target version and installer selection

function Get-LatestVersion() {
    Log "Checking for latest version of app"
    $resp = $null
    try {
        # -MaximumRedirection 0 makes the request "fail" on the redirect; the Location header holds the latest file name
        $resp = Invoke-WebRequest -Uri "https://www.banyanops.com/app/windows/v3/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing
    }
    catch {
        $resp = $_.Exception.Response
    }
    if ($resp) {
        $loc = [string]$resp.Headers.Location
        if ($loc -match 'sonicwallcse-([0-9]+\.[0-9]+\.[0-9]+)') {
            return $matches[1].Trim()
        }
    }
    return $null
}

# Device-manager variants ship with a "<YOUR_APP_VERSION (optional)>" placeholder; treat it as "latest"
if ($APP_VERSION -and $APP_VERSION.StartsWith("<")) { $APP_VERSION = "" }
if (!$APP_VERSION) {
    $APP_VERSION = Get-LatestVersion
    if (!$APP_VERSION) { Fail "Could not determine the latest app version and no APP_VERSION was given" }
}
if ($APP_VERSION -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Fail "APP_VERSION '$APP_VERSION' is not in the form X.Y.Z" }
$TARGET_VERSION = [version]$APP_VERSION

if ($INSTALLER_TYPE -ne "msi" -and $INSTALLER_TYPE -ne "exe") { Fail "INSTALLER_TYPE must be 'msi' or 'exe'" }
if ($INSTALLER_TYPE -eq "msi" -and $TARGET_VERSION -lt [version]"4.3.0") {
    Log "MSI installer is only available for 4.3.0 and later; falling back to EXE for $APP_VERSION"
    $INSTALLER_TYPE = "exe"
}

# Native ARM64 builds exist from 4.5.0. The machine-wide environment value is reliable even when
# this PowerShell process runs emulated.
$os_arch = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
$ARCH_SUFFIX = ""
if ($os_arch -eq "ARM64" -and $TARGET_VERSION -ge [version]"4.5.0") { $ARCH_SUFFIX = "-arm64" }

$INSTALLER_FILE = "sonicwallcse-$APP_VERSION$ARCH_SUFFIX.$INSTALLER_TYPE"
$INSTALLER_URL = "https://www.banyanops.com/app/releases/$INSTALLER_FILE"

if ($UPGRADE_FLOW) {
    Log "Running upgrade / true-up flow"
} else {
    Log "Running zero-touch install flow"
    Log "Installing with invite code: $INVITE_CODE"
    Log "Installing using deploy key: *****"
}
Log "Target app version: $APP_VERSION ($INSTALLER_TYPE, arch=$os_arch)"

$logged_on_user = Get-WMIObject -class Win32_ComputerSystem | Select-Object -expand UserName
Log "Logged-on user: $logged_on_user"


################################################################################
# Inventory of existing installs

function Get-CseInstallEntries() {
    # Returns every Banyan / CSE entry under the Uninstall registry key, from the 64-bit and
    # 32-bit HKLM views and from every loaded user hive (per-user NSIS installs).
    $entries = @()
    $subkey = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    $roots = @()
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $roots += @{ Hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view); Scope = "Machine" }
    }
    try {
        $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Registry64)
        foreach ($sid in $users.GetSubKeyNames()) {
            if ($sid -notmatch '^S-1-5-21-' -or $sid -like '*_Classes') { continue }
            $hk = $users.OpenSubKey($sid)
            if ($hk) { $roots += @{ Hive = $hk; Scope = "User:$sid" } }
        }
    } catch { }

    foreach ($r in $roots) {
        $key = $r.Hive.OpenSubKey($subkey)
        if (-not $key) { continue }
        foreach ($name in $key.GetSubKeyNames()) {
            $k = $key.OpenSubKey($name)
            if (-not $k) { continue }
            $dn = [string]$k.GetValue("DisplayName")
            $pub = [string]$k.GetValue("Publisher")
            if (-not $dn) { continue }
            $isLegacy = ($name -ieq $LEGACY_EXE_GUID) -or (($dn -match '^(Banyan|CSE)(\s|$)') -and ($pub -match 'Banyan|SonicWall'))
            $isCse = ($name -ieq $CSE_EXE_GUID) -or ($dn -match '^SonicWall Cloud Secure Edge')
            if (-not ($isLegacy -or $isCse)) { continue }
            $us = [string]$k.GetValue("UninstallString")
            $qus = [string]$k.GetValue("QuietUninstallString")
            $isMsi = ([string]$k.GetValue("WindowsInstaller") -eq "1") -or ($us -match 'msiexec')
            $kind = "CseExe"
            if ($isLegacy) { $kind = "LegacyExe" } elseif ($isMsi) { $kind = "CseMsi" }
            # electron-builder leaves InstallLocation empty in the Uninstall entry; derive it from the uninstaller path
            $loc = [string]$k.GetValue("InstallLocation")
            if (-not $loc -and -not $isMsi) {
                $parts = Split-UninstallString $(if ($qus) { $qus } else { $us })
                if ($parts[0]) { $loc = Split-Path $parts[0] -Parent }
            }
            $entries += [pscustomobject]@{
                Kind                 = $kind
                KeyName              = $name
                DisplayName          = $dn
                Version              = [string]$k.GetValue("DisplayVersion")
                Publisher            = $pub
                Scope                = $r.Scope
                InstallLocation      = $loc
                UninstallString      = $us
                QuietUninstallString = $qus
            }
        }
    }
    return $entries
}

function Get-OrphanInstallDirs($entries) {
    # Install directories that may exist without a matching registry entry (half-finished
    # uninstalls, or per-user installs for profiles that are not loaded right now).
    $known = @($entries | ForEach-Object { $_.InstallLocation } | Where-Object { $_ })
    $candidates = @()
    foreach ($base in @($ProgramFiles64, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates += (Join-Path $base "Banyan"); $candidates += (Join-Path $base "CSE") }
    }
    foreach ($p in Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue) {
        foreach ($n in @("Banyan", "CSE", "SonicWall Cloud Secure Edge")) {
            $candidates += Join-Path $p.FullName "AppData\Local\Programs\$n"
        }
    }
    $dirs = @()
    foreach ($c in ($candidates | Select-Object -Unique)) {
        if ($c -and (Test-Path -LiteralPath $c) -and ($c -ne $CSE_INSTALL_DIR) -and ($known -notcontains $c)) { $dirs += $c }
    }
    return $dirs
}

function Get-InstalledRegistryVersion() {
    try { return [string](Get-ItemProperty $CSE_VERSION_REG_KEY -ErrorAction Stop).Version } catch { return "" }
}

function Get-ServiceBinPath($name) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if ($svc) { return [string]$svc.PathName }
    return ""
}

function Test-CseServicesHealthy() {
    foreach ($s in $CSE_SERVICES) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { return $false }
        if ((Get-ServiceBinPath $s) -notlike "*$CSE_INSTALL_DIR*") { return $false }
    }
    return $true
}

function Start-CseServices() {
    foreach ($s in $CSE_SERVICES) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Running") {
            Log "Starting service $s"
            Start-Service -Name $s -ErrorAction SilentlyContinue
        }
    }
}


################################################################################
# Removal of legacy and mismatched installs

function Stop-GuiProcesses() {
    Log "Stopping SonicWall Cloud Secure Edge / Banyan app processes"
    foreach ($p in $GUI_PROCESSES) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Remove-ServiceIfExists($name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Log "Stopping and deleting service $name"
    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
    & sc.exe delete $name | Out-Null
}

function Remove-LegacyServices() {
    foreach ($s in $LEGACY_SERVICES) { Remove-ServiceIfExists $s }
    foreach ($p in $LEGACY_PROCESSES) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # A 3.28.x install ships its own copy of the updater service pointing into the legacy directory
    $updaterPath = Get-ServiceBinPath "sonicwall-cse-updater"
    if ($updaterPath -and ($updaterPath -notlike "*$CSE_INSTALL_DIR*")) {
        Log "Updater service points at legacy path: $updaterPath"
        Remove-ServiceIfExists "sonicwall-cse-updater"
        Get-Process -Name "sonicwall-cse-updater" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Remove-CseServices() {
    foreach ($s in $CSE_SERVICES) { Remove-ServiceIfExists $s }
    foreach ($s in $CSE_SERVICES) {
        Get-Process -Name $s -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Split-UninstallString($s) {
    # Returns @(exePath, extraArgs) from an NSIS UninstallString
    if ($s -match '^\s*"([^"]+\.exe)"\s*(.*)$') { return @($matches[1], $matches[2].Trim()) }
    if ($s -match '^\s*(\S+\.exe)\s*(.*)$') { return @($matches[1], $matches[2].Trim()) }
    return @("", "")
}

function Invoke-NsisUninstall($exePath, $extraArgs) {
    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) {
        Log "Uninstaller not found: $exePath"
        return $false
    }
    $dir = Split-Path $exePath -Parent
    $extra = ($extraArgs -replace '(?i)(^|\s)/S(\s|$)', ' ').Trim()
    # /S = silent. _?=<dir> makes the NSIS uninstaller run in place instead of copying itself to
    # %TEMP% and returning immediately, so -Wait really waits. It must be last and unquoted.
    $argLine = "/S $extra _?=$dir".Trim() -replace '\s+', ' '
    Log "Running uninstaller: `"$exePath`" $argLine"
    try {
        $p = Start-Process -FilePath $exePath -ArgumentList $argLine -Wait -PassThru -ErrorAction Stop
        Log "Uninstaller exit code: $($p.ExitCode)"
    } catch {
        Log "Uninstaller failed to start: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $dir) {
        Log "Removing leftover directory $dir"
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return (-not (Test-Path -LiteralPath $dir))
}

function Invoke-MsiUninstall($productCode) {
    $log = Join-Path $tmp_dir "sonicwallcse-uninstall-$productCode.log"
    Log "Uninstalling MSI product $productCode"
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $productCode /quiet /norestart /l*v `"$log`"" -Wait -PassThru
    Log "msiexec exit code: $($p.ExitCode) (log: $log)"
    return ($p.ExitCode -in @(0, 1605, 3010))
}

function Remove-RegistryRemnants() {
    foreach ($guid in @($LEGACY_EXE_GUID)) {
        foreach ($path in @("HKLM:\SOFTWARE\$guid", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid")) {
            if (Test-Path $path) {
                $loc = [string](Get-ItemProperty $path -ErrorAction SilentlyContinue).InstallLocation
                if (-not $loc -or -not (Test-Path -LiteralPath $loc)) {
                    Log "Removing stale registry key $path"
                    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

function Remove-UnwantedInstalls($entries, $orphans) {
    # Decide what has to go so that exactly one install (the target) remains
    $removed = 0
    foreach ($e in $entries) {
        $remove = $false
        $reason = ""
        switch ($e.Kind) {
            "LegacyExe" { $remove = $true; $reason = "legacy 3.x install" }
            "CseExe" {
                if ($INSTALLER_TYPE -eq "msi") { $remove = $true; $reason = "EXE install blocks the MSI installer" }
                elseif ($e.Scope -ne "Machine") { $remove = $true; $reason = "per-user install" }
                elseif ($e.Version -and ([version]$e.Version -ne $TARGET_VERSION)) { $remove = $true; $reason = "version $($e.Version) does not match target" }
                elseif ($FORCE_REINSTALL) { $remove = $true; $reason = "forced reinstall" }
            }
            "CseMsi" {
                if ($INSTALLER_TYPE -eq "exe") { $remove = $true; $reason = "MSI install blocks the EXE installer" }
                elseif ($e.Version -and ([version]$e.Version -gt $TARGET_VERSION)) { $remove = $true; $reason = "installed $($e.Version) is newer than target (downgrade requires uninstall)" }
                # same or older MSI version: msiexec upgrades it in place
            }
        }
        if (-not $remove) { continue }
        if ($DRY_RUN) { Log "DRY RUN: would remove $($e.DisplayName) $($e.Version) [$($e.Kind), $($e.Scope)]: $reason"; $removed++; continue }
        Log "Removing $($e.DisplayName) $($e.Version) [$($e.Kind), $($e.Scope)]: $reason"
        if ($e.Kind -eq "CseMsi") {
            Remove-CseServices
            if (Invoke-MsiUninstall $e.KeyName) { $removed++ }
            continue
        }
        if ($e.Kind -eq "LegacyExe") { Remove-LegacyServices } else { Remove-CseServices }
        $parts = Split-UninstallString $(if ($e.QuietUninstallString) { $e.QuietUninstallString } else { $e.UninstallString })
        $exe = $parts[0]; $extra = $parts[1]
        if (-not $exe -and $e.InstallLocation) {
            $exe = Get-ChildItem -LiteralPath $e.InstallLocation -Filter "Uninstall*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($e.Scope -ne "Machine") {
            Log "Per-user install for $($e.Scope); the uninstaller runs from the user's profile. Its registry entry may remain until that user signs in."
        }
        if (Invoke-NsisUninstall $exe $extra) { $removed++ } else { Log "WARNING: $($e.DisplayName) may not have been removed completely" }
    }

    foreach ($dir in $orphans) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        if ($DRY_RUN) { Log "DRY RUN: would remove directory without a matching registry entry: $dir"; $removed++; continue }
        Log "Found install directory without a matching registry entry: $dir"
        $uninst = Get-ChildItem -LiteralPath $dir -Filter "Uninstall*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($uninst) {
            if (Invoke-NsisUninstall $uninst "") { $removed++ }
        } else {
            Remove-LegacyServices
            Log "Removing directory $dir"
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }

    if ($DRY_RUN) {
        foreach ($s in $LEGACY_SERVICES) { if (Get-Service -Name $s -ErrorAction SilentlyContinue) { Log "DRY RUN: would delete legacy service $s" } }
        return $removed
    }
    Remove-LegacyServices
    Remove-RegistryRemnants
    return $removed
}


################################################################################
# Config, download, install, stage, start

$MY_USER = ""
$MY_EMAIL = ""
function get_user_email() {
    if (!$MULTI_USER) {
        # for a single user device, assumes you can get user and email because device is joined to an
        # Azure AD domain: https://nerdymishka.com/articles/azure-ad-domain-join-registry-keys/
        # (you may use other techniques here as well)
        $intune_info = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
        if (Test-Path $intune_info) {
            Log "Extracting user email from: $intune_info"
            $ADJoinInfo = Get-ChildItem -path $intune_info
            $ADJoinInfo = $ADJoinInfo -replace "HKEY_LOCAL_MACHINE","HKLM:"
            $ADJoinUser = Get-ItemProperty -Path $ADJoinInfo
            $script:MY_EMAIL = [string]$ADJoinUser.UserEmail
            if ($script:MY_EMAIL) { $script:MY_USER = $script:MY_EMAIL.Split("@")[0] }
        }
    }
    Log "Installing for user with name: $MY_USER"
    Log "Installing for user with email: $MY_EMAIL"
    if (!$MY_EMAIL) {
        Log "No user specified - device certificate will be issued to the default **STAGED USER**"
    }
}

function create_config() {
    Log "Creating mdm-config json file"

    $json = [pscustomobject]@{
        mdm_invite_code = $INVITE_CODE
        mdm_deploy_user = $MY_USER
        mdm_deploy_email = $MY_EMAIL
        mdm_device_ownership = $DEVICE_OWNERSHIP
        mdm_ca_certs_preinstalled = $CA_CERTS_PREINSTALLED
        mdm_skip_cert_suppression = $SKIP_CERT_SUPPRESSION
        mdm_present = $IS_MANAGED_DEVICE
        mdm_vendor_name = $DEVICE_MANAGER_NAME
        mdm_hide_services = $HIDE_SERVICES
        mdm_disable_quit = $DISABLE_QUIT
        mdm_start_at_boot = $START_AT_BOOT
        mdm_auto_login = $AUTO_LOGIN
        mdm_hide_on_start = $HIDE_ON_START
        mdm_disable_auto_update = $DISABLE_AUTO_UPDATE
        mdm_multi_org = $ALLOW_MULTIORG
        mdm_st_over_443 = $ST_OVER_443
    } | ConvertTo-Json

    New-Item -Path $CSE_CONFIG_DIR -ItemType "directory" -Force | Out-Null
    Set-Content -Path $CSE_CONFIG_FILE -Value $json -NoNewLine
}

function migrate_legacy_config() {
    # A device that was zero-touch installed on 3.x keeps its mdm-config.json in the old directory.
    # 4.x reads C:\ProgramData\SonicWallCSE\mdm-config.json. Keys are identical between versions.
    if (Test-Path $CSE_CONFIG_FILE) { return }
    foreach ($f in $LEGACY_CONFIG_FILES) {
        if (Test-Path $f) {
            Log "Migrating legacy mdm-config.json from $f"
            New-Item -Path $CSE_CONFIG_DIR -ItemType "directory" -Force | Out-Null
            Copy-Item -Path $f -Destination $CSE_CONFIG_FILE -Force
            return
        }
    }
}

function download_installer() {
    $dl_file = Join-Path $tmp_dir $INSTALLER_FILE
    Log "Downloading $INSTALLER_URL"
    try {
        Invoke-WebRequest -Uri $INSTALLER_URL -OutFile $dl_file -UseBasicParsing -ErrorAction Stop
    } catch {
        Fail "Download failed: $($_.Exception.Message)"
    }
    if (-not (Test-Path $dl_file) -or (Get-Item $dl_file).Length -lt 10MB) {
        Fail "Downloaded file is missing or too small: $dl_file"
    }
    if ($VERIFY_SIGNATURE) {
        $sig = Get-AuthenticodeSignature -FilePath $dl_file
        if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notmatch "SonicWall") {
            Fail "Installer signature check failed (status=$($sig.Status), subject=$($sig.SignerCertificate.Subject))"
        }
        Log "Installer signature valid: $($sig.SignerCertificate.Subject)"
    }
    return $dl_file
}

function Bool($b) { if ($b) { return "true" } else { return "false" } }

function install_msi($dl_file) {
    $log = Join-Path $tmp_dir "sonicwallcse-$APP_VERSION-install.log"
    $props = @(
        "DEVICE_OWNERSHIP=`"$DEVICE_OWNERSHIP`"",
        "CA_CERTS_PREINSTALLED=$(Bool $CA_CERTS_PREINSTALLED)",
        "SKIP_CERT_SUPPRESSION=$(Bool $SKIP_CERT_SUPPRESSION)",
        "IS_MANAGED_DEVICE=$(Bool $IS_MANAGED_DEVICE)",
        "DEVICE_MANAGER_NAME=`"$DEVICE_MANAGER_NAME`"",
        "HIDE_SERVICES=$(Bool $HIDE_SERVICES)",
        "DISABLE_QUIT=$(Bool $DISABLE_QUIT)",
        "START_AT_BOOT=$(Bool $START_AT_BOOT)",
        "AUTO_LOGIN=$(Bool $AUTO_LOGIN)",
        "HIDE_ON_START=$(Bool $HIDE_ON_START)",
        "DISABLE_AUTO_UPDATE=$(Bool $DISABLE_AUTO_UPDATE)",
        "ALLOW_MULTIORG=$(Bool $ALLOW_MULTIORG)",
        "ST_OVER_443=$(Bool $ST_OVER_443)",
        "MULTI_USER=$(Bool $MULTI_USER)",
        "ALLOW_APP=$(Bool $ALLOW_APP)",
        "SKIP_LAUNCH=1"
    )
    $secret = @()
    if (-not $UPGRADE_FLOW) {
        $props += "INVITE_CODE=`"$INVITE_CODE`""
        $props += "DEPLOY_USER=`"$MY_USER`""
        $props += "DEPLOY_EMAIL=`"$MY_EMAIL`""
        $secret += "DEPLOYMENT_KEY=`"$DEPLOYMENT_KEY`""
    }
    $shown = "/i `"$dl_file`" /quiet /norestart $($props -join ' ') $(if ($secret) { 'DEPLOYMENT_KEY=*****' }) /l*v `"$log`""
    Log "Running: msiexec.exe $shown"
    $argLine = "/i `"$dl_file`" /quiet /norestart $(($props + $secret) -join ' ') /l*v `"$log`""
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $argLine -Wait -PassThru
    Log "msiexec exit code: $($p.ExitCode) (log: $log)"
    if ($p.ExitCode -eq 3010) { Log "A reboot is recommended to complete the install" }
    elseif ($p.ExitCode -ne 0) { Fail "MSI install failed with exit code $($p.ExitCode); see $log" }
}

function install_exe($dl_file) {
    Log "Running EXE installer silently"
    $p = Start-Process -FilePath $dl_file -ArgumentList "/S /SkipLaunch" -Wait -PassThru
    Log "Installer exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { Fail "EXE install failed with exit code $($p.ExitCode)" }
    Start-Sleep -Seconds 3
}

function stage() {
    Log "Running staged deployment"
    $ADMIN_SERVER = "sonicwall-cse-admin.exe"
    if (Test-Path (Join-Path $CSE_BIN_DIR "sonicwall-cse-admin-worker.exe")) { $ADMIN_SERVER = "sonicwall-cse-admin-worker.exe" }
    $process = Start-Process -FilePath (Join-Path $CSE_BIN_DIR $ADMIN_SERVER) -ArgumentList "stage --key=$DEPLOYMENT_KEY" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Fail "Error during staged deployment (exit code $($process.ExitCode))"
    }
    Start-Sleep -Seconds 3
    Log "Staged deployment done. Have the logged_on_user start the SonicWall Cloud Secure Edge app to complete registration."
}

function verify_install() {
    if (-not (Test-Path $CSE_EXE)) { Fail "Install verification failed: $CSE_EXE not found" }
    $regVersion = Get-InstalledRegistryVersion
    if ($regVersion -and ([version]$regVersion -ne $TARGET_VERSION)) { Fail "Install verification failed: registry reports version $regVersion, expected $APP_VERSION" }
    if (-not (Test-CseServicesHealthy)) { Fail "Install verification failed: one or more CSE services are missing or point at the wrong path" }
    Start-CseServices
    $remaining = Get-CseInstallEntries | Where-Object { $_.Kind -eq "LegacyExe" }
    if ($remaining) { Log "WARNING: legacy entries still present: $(($remaining | ForEach-Object { "$($_.DisplayName) [$($_.Scope)]" }) -join ', ')" }
    Log "Verified: SonicWall Cloud Secure Edge $APP_VERSION installed, services present"
}

function create_scheduled_task($task_name) {
    Log "Creating ScheduledTask $task_name for logged_on_user, so app launches upon next user login"
    $action = New-ScheduledTaskAction -Execute $CSE_EXE
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $logged_on_user
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal
    Register-ScheduledTask $task_name -InputObject $task | Out-Null
}

function delete_scheduled_task($task_name) {
    Log "Deleting ScheduledTask $task_name"
    Unregister-ScheduledTask -TaskName $task_name -Confirm:$false -ErrorAction SilentlyContinue
}

# since Windows doesn't have "su - username", we use scheduled_task to launch SonicWall Cloud Secure Edge app as logged_on user
function start_app() {
    if (-not $logged_on_user) {
        Log "No interactive user logged on; the app will start at next login"
        return
    }
    Log "Running ScheduledTask to start the SonicWall Cloud Secure Edge app as: $logged_on_user"
    $task_name = "StartSonicWallCSETemp"
    try {
        create_scheduled_task($task_name)
        Start-ScheduledTask -TaskName $task_name
        Start-Sleep -Seconds 5
    } catch {
        Log "Could not start the app for $logged_on_user : $($_.Exception.Message)"
    } finally {
        delete_scheduled_task($task_name)
    }
}

function allow_app() {
    if ($ALLOW_APP -and -not (Get-NetFirewallRule -DisplayName "SonicWall-CSE-App" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName "SonicWall-CSE-App" `
            -Program $CSE_EXE `
            -Direction Outbound `
            -Action Allow `
            -Profile Public,Private,Domain | Out-Null
    }
}


################################################################################
# Main

$entries = @(Get-CseInstallEntries)
$orphans = @(Get-OrphanInstallDirs $entries)

Log "Existing installs found: $($entries.Count)"
foreach ($e in $entries) { Log "  - $($e.DisplayName) $($e.Version) [$($e.Kind), $($e.Scope)] $($e.InstallLocation)" }
foreach ($d in $orphans) { Log "  - directory without registry entry: $d" }

$legacyCount = @($entries | Where-Object { $_.Kind -eq "LegacyExe" }).Count
$targetKind = if ($INSTALLER_TYPE -eq "msi") { "CseMsi" } else { "CseExe" }
$current = @($entries | Where-Object { $_.Kind -eq $targetKind -and $_.Scope -eq "Machine" })
$alreadyClean = ($legacyCount -eq 0) -and ($orphans.Count -eq 0) -and ($entries.Count -eq 1) -and ($current.Count -eq 1) `
    -and $current[0].Version -and ([version]$current[0].Version -eq $TARGET_VERSION) -and (Test-CseServicesHealthy)

if ($alreadyClean -and -not $FORCE_REINSTALL) {
    Log "Device is already clean and at $APP_VERSION ($INSTALLER_TYPE). Nothing to do."
    Start-CseServices
    if (-not $UPGRADE_FLOW -and -not (Test-Path $CSE_CONFIG_FILE)) {
        Log "mdm-config.json missing; writing it"
        get_user_email
        create_config
    }
    exit 0
}

if (-not $DRY_RUN) { Stop-GuiProcesses }

if ($REMOVE_LEGACY) {
    $removed = Remove-UnwantedInstalls $entries $orphans
    Log "$(if ($DRY_RUN) { 'Would remove' } else { 'Removed' }) $removed install(s)"
} elseif ($legacyCount -gt 0) {
    Log "WARNING: legacy installs present but REMOVE_LEGACY is false; the result will be a side-by-side install"
}

if ($DRY_RUN) {
    Log "DRY RUN: would download $INSTALLER_URL and install $APP_VERSION via $INSTALLER_TYPE ($(if ($UPGRADE_FLOW) { 'upgrade flow, no re-staging' } else { 'zero-touch install flow with staging' }))"
    if ($UPGRADE_FLOW -and -not (Test-Path $CSE_CONFIG_FILE)) {
        foreach ($f in $LEGACY_CONFIG_FILES) { if (Test-Path $f) { Log "DRY RUN: would migrate mdm-config.json from $f" } }
    }
    exit 0
}

if ($UPGRADE_FLOW) {
    migrate_legacy_config
    $dl_file = download_installer
    if ($INSTALLER_TYPE -eq "msi") { install_msi $dl_file } else { install_exe $dl_file }
    verify_install
    start_app
} else {
    get_user_email
    $dl_file = download_installer
    if ($INSTALLER_TYPE -eq "msi") {
        # The MSI writes mdm-config.json and the deployment key itself from the properties passed
        install_msi $dl_file
        if (-not (Test-Path $CSE_CONFIG_FILE)) { create_config }
    } else {
        create_config
        install_exe $dl_file
        stage
        create_config
    }
    verify_install
    allow_app
    start_app
}

Remove-Item -Path $dl_file -Force -ErrorAction SilentlyContinue
Log "Done"
exit 0
