#!/bin/bash
# Read-only inventory of SonicWall Cloud Secure Edge / Banyan installs on a Mac. Makes no changes.
#
# Exit codes (so an RMM can flag devices that need the installer script run):
#   0  clean: 4.x app present, no legacy components, launch daemons present
#   2  needs remediation: legacy 3.x present, or 4.x daemons missing
#   3  no Banyan / CSE install found

CSE_APP="/Applications/SonicWall Cloud Secure Edge.app"
LEGACY_APP="/Applications/Banyan.app"
LEGACY_DAEMONS=(/Library/LaunchDaemons/com.banyan.banyanapp-admin.plist /Library/LaunchDaemons/com.banyan.banyanwgs.plist)
CSE_DAEMONS=(/Library/LaunchDaemons/com.sonicwall.cse-admin.plist /Library/LaunchDaemons/com.sonicwall.csewgs.plist /Library/LaunchDaemons/com.sonicwall.sonicwall-cse-updater.plist)

cse_version=""
[[ -d "$CSE_APP" ]] && cse_version=$(/usr/bin/defaults read "${CSE_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
legacy_version=""
[[ -d "$LEGACY_APP" ]] && legacy_version=$(/usr/bin/defaults read "${LEGACY_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)

legacy_daemons=0
for p in "${LEGACY_DAEMONS[@]}"; do [[ -f "$p" ]] && legacy_daemons=$((legacy_daemons+1)); done
cse_daemons=0
for p in "${CSE_DAEMONS[@]}"; do [[ -f "$p" ]] && cse_daemons=$((cse_daemons+1)); done

state="unknown"; rc=2
if [[ -z "$cse_version" && -z "$legacy_version" && $legacy_daemons -eq 0 && $cse_daemons -eq 0 ]]; then
    state="none"; rc=3
elif [[ -n "$cse_version" && ( -n "$legacy_version" || $legacy_daemons -gt 0 ) ]]; then
    state="side-by-side"
elif [[ -n "$legacy_version" || $legacy_daemons -gt 0 ]]; then
    state="legacy-only"
elif [[ -n "$cse_version" && $cse_daemons -eq 3 ]]; then
    state="clean"; rc=0
elif [[ -n "$cse_version" ]]; then
    state="daemons-unhealthy"
else
    state="remnants-only"
fi

echo "CSE_STATE=$state CSE_VERSION=$cse_version LEGACY_VERSION=$legacy_version CSE_DAEMONS=$cse_daemons LEGACY_DAEMONS=$legacy_daemons"
echo "MDM_CONFIG=$( [[ -f /etc/sonicwallcse/mdm-config.json ]] && echo yes || echo no ) LEGACY_MDM_CONFIG=$( [[ -f /etc/banyanapp/mdm-config.json ]] && echo yes || echo no )"
exit $rc
