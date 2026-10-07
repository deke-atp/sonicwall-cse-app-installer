# Read-only inventory of SonicWall Cloud Secure Edge / Banyan installs on a Windows device.
#
# Prints a one-line state, then a JSON document with every install found, the CSE services
# and their binary paths, and whether an mdm-config.json exists. Makes no changes.
#
# Exit codes (so an RMM can flag devices that need the installer script run):
#   0  clean: exactly one 4.x install, services healthy
#   2  needs remediation: legacy 3.x present, side-by-side installs, orphaned directories,
#      or services pointing at the wrong path
#   3  no Banyan / CSE install found
#
# Optional: set $NINJA_CUSTOM_FIELD to a NinjaOne device custom field name to store the state.

$NINJA_CUSTOM_FIELD = ""

$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$CSE_INSTALL_DIR = Join-Path $ProgramFiles64 "SonicWall Cloud Secure Edge"
$CSE_EXE_GUID = "4d8a012d-c95e-5593-8a34-2f8eac9d19dd"
$LEGACY_EXE_GUID = "801388f2-a9e0-5ca9-a9e7-de7a5cb4e1c2"
$ALL_SERVICES = @("banyanapp-admin", "banyan-wgs", "sonicwall-cse-admin", "sonicwall-cse-wgs", "sonicwall-cse-updater")
$CSE_SERVICES = @("sonicwall-cse-admin", "sonicwall-cse-wgs", "sonicwall-cse-updater")

function Get-CseInstallEntries() {
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
            $isMsi = ([string]$k.GetValue("WindowsInstaller") -eq "1") -or ($us -match 'msiexec')
            $kind = "CseExe"
            if ($isLegacy) { $kind = "LegacyExe" } elseif ($isMsi) { $kind = "CseMsi" }
            # electron-builder leaves InstallLocation empty in the Uninstall entry; derive it from the uninstaller path
            $loc = [string]$k.GetValue("InstallLocation")
            if (-not $loc -and -not $isMsi -and $us -match '^\s*"?([^"]+\.exe)') { $loc = Split-Path $matches[1] -Parent }
            $entries += [pscustomobject]@{
                Kind            = $kind
                DisplayName     = $dn
                Version         = [string]$k.GetValue("DisplayVersion")
                Scope           = $r.Scope
                InstallLocation = $loc
                UninstallString = $us
            }
        }
    }
    return $entries
}

function Get-OrphanInstallDirs($entries) {
    $known = @($entries | ForEach-Object { $_.InstallLocation } | Where-Object { $_ })
    $candidates = @()
    foreach ($base in @($ProgramFiles64, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates += (Join-Path $base "Banyan"); $candidates += (Join-Path $base "CSE") }
    }
    foreach ($p in Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue) {
        foreach ($n in @("Banyan", "CSE", "SonicWall Cloud Secure Edge")) { $candidates += Join-Path $p.FullName "AppData\Local\Programs\$n" }
    }
    $dirs = @()
    foreach ($c in ($candidates | Select-Object -Unique)) {
        if ($c -and (Test-Path -LiteralPath $c) -and ($c -ne $CSE_INSTALL_DIR) -and ($known -notcontains $c)) { $dirs += $c }
    }
    return $dirs
}

$entries = @(Get-CseInstallEntries)
$orphans = @(Get-OrphanInstallDirs $entries)
$services = @()
foreach ($s in $ALL_SERVICES) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
    if ($svc) { $services += [pscustomobject]@{ Name = $s; State = $svc.State; StartMode = $svc.StartMode; Path = $svc.PathName } }
}
$regVersion = ""
try { $regVersion = [string](Get-ItemProperty "HKLM:\SOFTWARE\SonicWall\CloudSecureEdge" -ErrorAction Stop).Version } catch { }

$legacy = @($entries | Where-Object { $_.Kind -eq "LegacyExe" })
$cse = @($entries | Where-Object { $_.Kind -ne "LegacyExe" })
$legacyServices = @($services | Where-Object { $_.Name -in @("banyanapp-admin", "banyan-wgs") -or ($_.Path -and $_.Path -notlike "*$CSE_INSTALL_DIR*") })
$cseServicesPresent = @($services | Where-Object { $_.Name -in $CSE_SERVICES -and $_.Path -like "*$CSE_INSTALL_DIR*" }).Count

$state = "unknown"
$exit = 2
if ($entries.Count -eq 0 -and $orphans.Count -eq 0 -and $services.Count -eq 0) {
    $state = "none"; $exit = 3
} elseif ($legacy.Count -gt 0 -and $cse.Count -gt 0) {
    $state = "side-by-side"
} elseif ($legacy.Count -gt 0) {
    $state = "legacy-only"
} elseif ($cse.Count -gt 1 -or $orphans.Count -gt 0) {
    $state = "multiple-installs"
} elseif ($cse.Count -eq 1 -and $legacyServices.Count -eq 0 -and $cseServicesPresent -eq 3) {
    $state = "clean-$($cse[0].Kind.ToLower().Replace('cse',''))"; $exit = 0
} elseif ($cse.Count -eq 1) {
    $state = "services-unhealthy"
} else {
    $state = "remnants-only"
}

$versions = @($entries | ForEach-Object { "$($_.DisplayName) $($_.Version)" }) -join "; "
Write-Host "CSE_STATE=$state VERSIONS=[$versions] REG_VERSION=$regVersion"

[pscustomobject]@{
    ComputerName    = $env:COMPUTERNAME
    State           = $state
    RegistryVersion = $regVersion
    Installs        = $entries
    OrphanDirs      = $orphans
    Services        = $services
    MdmConfig       = (Test-Path "C:\ProgramData\SonicWallCSE\mdm-config.json")
    LegacyMdmConfig = ((Test-Path "C:\ProgramData\CSE\mdm-config.json") -or (Test-Path "C:\ProgramData\banyanapp\mdm-config.json"))
} | ConvertTo-Json -Depth 4

if ($NINJA_CUSTOM_FIELD -and (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)) {
    try { Ninja-Property-Set $NINJA_CUSTOM_FIELD "$state $versions" } catch { Write-Host "Could not set Ninja custom field: $($_.Exception.Message)" }
}

exit $exit
