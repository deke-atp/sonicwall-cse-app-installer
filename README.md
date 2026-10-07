# SonicWall Cloud Secure Edge App Installer

Automate installation, upgrade and version true-up of the SonicWall Cloud Secure Edge (CSE) desktop app on end-user devices.

See [SonicWall Cloud Secure Edge documentation](https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/distribute-desktopapp/) for more details.

This is the Axios / DaVinci fork of [banyansecurity/sonicwall-cse-app-installer](https://github.com/banyansecurity/sonicwall-cse-app-installer). It adds legacy (3.x) cleanup, MSI support, verification and fleet-safe idempotency on top of the vendor scripts.

---

## Why the 3.x to 4.x upgrade needs a script

Desktop app 4.0.0 (February 2026) rebranded the product. The executable, services, directories and installer identity all changed:

| | 3.x (legacy Banyan) | 4.x (SonicWall CSE) |
|---|---|---|
| Windows install dir | `C:\Program Files\Banyan` (or `\CSE`) | `C:\Program Files\SonicWall Cloud Secure Edge` |
| Windows uninstaller | `Uninstall Banyan.exe` | `Uninstall SonicWall Cloud Secure Edge.exe` or MSI |
| Windows services | `banyanapp-admin`, `banyan-wgs`, `sonicwall-cse-updater` | `sonicwall-cse-admin`, `sonicwall-cse-wgs`, `sonicwall-cse-updater` |
| Windows config dir | `C:\ProgramData\CSE` or `\banyanapp` | `C:\ProgramData\SonicWallCSE` |
| Windows installer GUID | `801388f2-a9e0-5ca9-a9e7-de7a5cb4e1c2` | `4d8a012d-c95e-5593-8a34-2f8eac9d19dd` (EXE), UpgradeCode `{4B3F5D91-8E2A-47C6-9F1B-2D0A6E3C8B74}` (MSI) |
| macOS app | `/Applications/Banyan.app` | `/Applications/SonicWall Cloud Secure Edge.app` |
| macOS daemons | `com.banyan.banyanapp-admin`, `com.banyan.banyanwgs` | `com.sonicwall.cse-admin`, `com.sonicwall.csewgs`, `com.sonicwall.sonicwall-cse-updater` |
| macOS config dir | `/etc/banyanapp` | `/etc/sonicwallcse` |

Because the Windows installer identity changed, Windows Installer and NSIS treat 4.x as a different product. The 4.x EXE installer only removes a 3.x install that lives in `C:\Program Files\Banyan`, and it does so without waiting for the uninstaller to finish. The result on many devices was Banyan 3.x and CSE 4.x installed side by side with two sets of services. The macOS 4.x package removes `Banyan.app` itself, so macOS is less affected.

`https://www.banyanops.com/app/windows/v3/latest` and `.../macos/v3/latest` now redirect to the 4.x build, so "latest" always means 4.x.

Other facts that shape the scripts (from the vendor docs and the installers themselves):

- The MSI is SonicWall's recommended installer for managed Windows devices on 4.3.0 and later. It upgrades in place, preserves `mdm-config.json`, certificates and tokens, and is eligible for auto-update. The MSI and EXE are mutually exclusive: the MSI refuses to install while a 4.x EXE install is present and the EXE refuses while the MSI is present. The MSI does not detect or remove 3.x.
- Downgrade prevention was added in 4.5.0. Installing an older version over a newer one is blocked without an uninstall first.
- Auto-update needs 4.2.0 or later. Devices on 3.x or on 4.0.x to 4.1.x need one managed update before auto-update takes over.
- Native ARM64 Windows installers exist from 4.5.0 (`-arm64` suffix).
- Current installers are Authenticode signed by `SonicWall Inc.`. The scripts verify this before installing.

---

## What the scripts do

Both the install flow and the upgrade flow on Windows and macOS now:

1. Inventory every Banyan / CSE install on the device (registry Uninstall entries in the 64-bit and 32-bit views and in loaded user hives, plus known install directories on Windows; app bundle and launch daemons on macOS).
2. Exit immediately with code 0 if the device already has exactly one install of the target version and type with healthy services. This makes the script safe to run against an entire device group.
3. Stop the app, stop and delete legacy services, and silently run the vendor uninstaller for every 3.x install, every 4.x EXE install when the target is MSI, and every 4.x install whose version does not match the target. User data is preserved so 4.x can migrate it.
4. Migrate an existing `mdm-config.json` from the legacy config directory (upgrade flow).
5. Download the target installer, verify the signature, and install silently (MSI with properties, or EXE followed by staging).
6. Verify the installed version, services and paths, start the services, and launch the app for the logged-on user.

The scripts exit non-zero on any failure so the RMM job reports it.

---

## Install using Zero Touch Flow

In the SonicWall Cloud Secure Edge Command Center, navigate to **Settings** > **CSE Client** > **Deployment**. Note down your org-specific app deployment parameters for use in the scripts below:
- Invite Code
- Deployment Key

### MacOS

Launch a terminal and run:

```bash
sudo ./sonicwall-cse-macos.sh <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional)>
```

### Windows

Launch PowerShell as Administrator and run:

```powershell
.\sonicwall-cse-windows.ps1 <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional)>
```

With the default `$INSTALLER_TYPE = "msi"` the MSI writes `mdm-config.json` and stages the device from the properties passed to it. Set `$INSTALLER_TYPE = "exe"` to use the legacy EXE flow (the script also falls back to EXE automatically for target versions earlier than 4.3.0).

### Linux

Launch a terminal and run:

```bash
sudo ./sonicwall-cse-linux.sh <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional)>
```
NOTE: The Linux script is the unmodified vendor script. It doesn't currently support MDM supplied user information and has no legacy cleanup.

---

## Upgrade / True-Up Flow

Use the string `"upgrade"` for the Invite Code and Deployment Key parameters. The device keeps its existing registration data; no re-staging is performed.

### MacOS

```bash
sudo ./sonicwall-cse-macos.sh upgrade upgrade <APP_VERSION (optional)>
```

### Windows

```powershell
.\sonicwall-cse-windows.ps1 upgrade upgrade <APP_VERSION (optional)>
```

### Linux

```bash
sudo ./sonicwall-cse-linux.sh upgrade <APP_VERSION (optional)>
```

---

## Inventory scripts (read-only)

`sonicwall-cse-windows-inventory.ps1` and `sonicwall-cse-macos-inventory.sh` report what is installed without changing anything. The first output line is a single `CSE_STATE=...` line, followed by detail (JSON on Windows). Exit codes:

| Exit | Meaning |
|---|---|
| 0 | clean: one 4.x install, services healthy |
| 2 | needs remediation: legacy 3.x present, side-by-side, orphaned directory, or services pointing at the wrong path |
| 3 | no Banyan / CSE install found |

On Windows, set `$NINJA_CUSTOM_FIELD` to a NinjaOne device custom field name to store the state on the device record.

---

## NinjaOne rollout (Axios)

1. Add `sonicwall-cse-windows.ps1` to the Ninja script library as a PowerShell script running as **System**, 64-bit. Preset parameters: `upgrade upgrade` (optionally followed by a pinned version such as `4.6.0`).
2. Optionally add `sonicwall-cse-windows-inventory.ps1` and run it against all workstations first. Devices exiting 2 are the ones that need the upgrade.
3. Pilot the upgrade on one or two 3.x devices and confirm: the app comes back, the user's org and registration carry over or the user can sign in once, and the inventory script then reports `clean-msi`.
4. Run the upgrade script against the 3.x device group. Running it again later is harmless; devices already at the target version exit 0 without changes.
5. Pin a version in the parameters if you want the fleet on a known build. Leave it blank to track the vendor's latest.

Expect the Service Tunnel to drop for one to two minutes during the upgrade. Schedule outside working hours where possible. The Ninja agent does not depend on CSE.

Per-user installs (someone ran the installer without admin rights) are detected from loaded user hives and removed where possible. Their registry entry may linger until that user signs in; the inventory script shows them with a `User:<SID>` scope.

---

## Notes for usage with Device Managers

We have pre-configured the main script to be run via Device Managers (such as VMware Workspace ONE, Jamf Pro, Kandji, Microsoft Intune, etc.). The variants in `device_manager/` are generated from the base scripts by `device_manager/_run.rb` and carry the same cleanup and verification logic.

### Jamf Pro

Use the [**sonicwall-cse-macos-jamf.sh**](device_manager/sonicwall-cse-macos-jamf.sh) script, following the [Jamf Pro - Zero Touch Installation doc](https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/jamf-pro-zero-touch/). [**sonicwall-macos-jamf-davinci.sh**](device_manager/sonicwall-macos-jamf-davinci.sh) is the same script with our defaults (corporate ownership, CA certs preinstalled, cert warnings not suppressed).

### Kandji

Use the [**sonicwall-cse-macos-kandji.sh**](device_manager/sonicwall-cse-macos-kandji.sh) script, following the [Kandji - Zero Touch Installation doc](https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/kandji-zero-touch/).

### Microsoft Intune

Use the [**sonicwall-cse-windows-intune.ps1**](device_manager/sonicwall-cse-windows-intune.ps1) script, following the [Intune - Zero Touch Installation doc](https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/intune-zero-touch/). For 4.3.0 and later SonicWall also documents a direct MSI deployment: [Installing the CSE Desktop App for Windows (MSI)](https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/windows-msi-install/).

### VMWare Workspace One UEM

Use our base scripts and customize as needed, following the [Workspace ONE UEM - Device Identity & Enhanced TrustScoring doc](https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/workspace-one-cert-api/#wsone). You need to set a few additional parameters in the `mdm-config.json` file so the TrustScoring engine can correlate data from devices running the desktop app with the data in Workspace ONE UEM:

- `mdm_vendor_name` should be set to **Airwatch**
- `mdm_present` should be **true**
- `mdm_vendor_udid` should be the **DEVICE UDID**

---

## Manual cleanup reference

If a device needs hands-on cleanup, these are the vendor-documented commands (run as administrator / root):

- Windows 3.x: `"C:\Program Files\Banyan\Uninstall Banyan.exe" /S` (or `...\CSE\...`)
- Windows 4.x EXE: `"C:\Program Files\SonicWall Cloud Secure Edge\Uninstall SonicWall Cloud Secure Edge.exe" /S`
- Windows 4.x MSI: `msiexec /x <ProductCode> /quiet /norestart`
- macOS 3.x: `/Applications/Banyan.app/Contents/Resources/conf/uninstall.sh`
- macOS 4.x: `"/Applications/SonicWall Cloud Secure Edge.app/Contents/Resources/conf/uninstall.sh"`

`full-delete` variants also remove user data and registrations; the scripts here never run them.
