#!/bin/bash
#
# 
# Based on the SonicWALL/Banyan provided Jamf script.  
# Updated to change default settings and pass variables 
# from Jamf for the Invite Code and Deployment Key.
#

################################################################################
# SonicWall Cloud Secure Edge Zero Touch Installation / Upgrade / Version True-Up
#
# Usage:
#   sudo ./sonicwall-cse-macos.sh <INVITE_CODE> <DEPLOYMENT_KEY> [APP_VERSION]   zero-touch install
#   sudo ./sonicwall-cse-macos.sh upgrade upgrade [APP_VERSION]                  upgrade / true-up
#
# Desktop app 4.0.0 renamed the app bundle (/Applications/Banyan.app became
# "/Applications/SonicWall Cloud Secure Edge.app"), the launch daemons and the config
# directory. Both flows below remove a legacy 3.x install cleanly before installing the
# target version, migrate an existing mdm-config.json, and do nothing when the device is
# already clean and at the target version, so the script is safe to run across a fleet.
#
# Confirm or update the following variables prior to running the script
################################################################################

# Deployment Information
# Obtain from the SonicWall Cloud Secure Edge admin console: Settings > CSE Client > Deployment
INVITE_CODE="$4"
DEPLOYMENT_KEY="$5"
APP_VERSION="$6"

# Device Registration and SonicWall Cloud Secure Edge App Configuration
# Check docs for more options and details:
# https://cse-docs.sonicwall.com/docs/manage-users-and-devices/device-managers/distribute-desktopapp/#mdm-config-json
DEVICE_OWNERSHIP="C"
CA_CERTS_PREINSTALLED=true
SKIP_CERT_SUPPRESSION=true
IS_MANAGED_DEVICE=true
DEVICE_MANAGER_NAME="Jamf"
HIDE_SERVICES=false
DISABLE_QUIT=false
START_AT_BOOT=true
AUTO_LOGIN=false
HIDE_ON_START=true
DISABLE_AUTO_UPDATE=false
ALLOW_MULTIORG=false
ST_OVER_443=false

# User Information for Device Certificate
MULTI_USER=false
USERINFO_PATH="/Library/Managed Preferences/userinfo.plist"
USERINFO_USER_VAR="deploy_user"
USERINFO_EMAIL_VAR="deploy_email"

# Remove a legacy Banyan 3.x install before installing
REMOVE_LEGACY=true

# Reinstall even when the device is already clean and at the target version
FORCE_REINSTALL=false

# Require a valid SonicWall / Banyan Developer ID signature on the downloaded package
VERIFY_SIGNATURE=true

################################################################################

log() { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERROR: $*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as the root user"
fi

if [[ -z "$INVITE_CODE" || -z "$DEPLOYMENT_KEY" ]]; then
    echo "Usage: "
    echo "$0 <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional)>"
    echo "$0 upgrade upgrade <APP_VERSION (optional)>"
    exit 1
fi

UPGRADE_FLOW=false
[[ "$INVITE_CODE" = "upgrade" && "$DEPLOYMENT_KEY" = "upgrade" ]] && UPGRADE_FLOW=true

# Well-known names
CSE_APP="/Applications/SonicWall Cloud Secure Edge.app"
CSE_ADMIN="${CSE_APP}/Contents/Resources/bin/sonicwall-cse-admin"
LEGACY_APP="/Applications/Banyan.app"
LEGACY_DAEMONS=(/Library/LaunchDaemons/com.banyan.banyanapp-admin.plist /Library/LaunchDaemons/com.banyan.banyanwgs.plist)
CSE_DAEMONS=(/Library/LaunchDaemons/com.sonicwall.cse-admin.plist /Library/LaunchDaemons/com.sonicwall.csewgs.plist /Library/LaunchDaemons/com.sonicwall.sonicwall-cse-updater.plist)
global_config_dir="/etc/sonicwallcse"
global_config_file="${global_config_dir}/mdm-config.json"
legacy_config_file="/etc/banyanapp/mdm-config.json"
tmp_dir="/etc/sonicwallcse/tmp"
mkdir -p "$tmp_dir"

# Device-manager variants ship with a "<YOUR_APP_VERSION (optional)>" placeholder; treat it as "latest"
[[ "$APP_VERSION" == \<* ]] && APP_VERSION=""
if [[ -z "$APP_VERSION" ]]; then
    log "Checking for latest version of app"
    APP_VERSION=$( curl --head -sL https://www.banyanops.com/app/macos/v3/latest | awk -F'-' '/[Ll]ocation/ {split($2, n, "."); print n[1]"."n[2]"."n[3]}' | tr -d '\r' )
    [[ -z "$APP_VERSION" ]] && fail "Could not determine the latest app version and no APP_VERSION was given"
fi
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "APP_VERSION '$APP_VERSION' is not in the form X.Y.Z"

if $UPGRADE_FLOW; then
    log "Running upgrade / true-up flow"
else
    log "Running zero-touch install flow"
    log "Installing with invite code: $INVITE_CODE"
    log "Installing using deploy key: *****"
fi
log "Target app version: $APP_VERSION"

logged_on_user=$( echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
log "Logged-on user: $logged_on_user"


################################################################################
# Inventory

installed_version() {
    # Prints the installed 4.x version, or nothing
    if [[ -d "$CSE_APP" ]]; then
        /usr/bin/defaults read "${CSE_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null
    fi
}

legacy_present() {
    [[ -d "$LEGACY_APP" ]] && return 0
    for p in "${LEGACY_DAEMONS[@]}"; do [[ -f "$p" ]] && return 0; done
    return 1
}

daemons_healthy() {
    for p in "${CSE_DAEMONS[@]}"; do [[ -f "$p" ]] || return 1; done
    return 0
}

load_daemons() {
    for p in "${CSE_DAEMONS[@]}"; do
        [[ -f "$p" ]] && /bin/launchctl load -w "$p" 2>/dev/null
    done
}


################################################################################
# Removal of the legacy install

stop_app() {
    log "Stopping SonicWall Cloud Secure Edge / Banyan app"
    for name in "SonicWall Cloud Secure Edge" "Banyan"; do
        /usr/bin/pkill -TERM -x "$name" 2>/dev/null
    done
    sleep 2
    for name in "SonicWall Cloud Secure Edge" "Banyan"; do
        /usr/bin/pkill -KILL -x "$name" 2>/dev/null
    done
}

remove_legacy() {
    legacy_present || return 0
    log "Removing legacy Banyan 3.x install"

    for p in "${LEGACY_DAEMONS[@]}"; do
        if [[ -f "$p" ]]; then
            /bin/launchctl unload -w "$p" 2>/dev/null
        fi
    done
    /usr/bin/pkill -KILL -x banyanapp-admin 2>/dev/null
    /usr/bin/pkill -KILL -x banyanwgs 2>/dev/null

    # The vendor uninstaller keeps user settings (/etc/banyanapp and per-user data) so 4.x can
    # migrate them. full-delete.sh would wipe them.
    local uninstaller="${LEGACY_APP}/Contents/Resources/conf/uninstall.sh"
    if [[ -x "$uninstaller" || -f "$uninstaller" ]]; then
        log "Running vendor uninstaller: $uninstaller"
        /bin/bash "$uninstaller" || log "WARNING: legacy uninstaller returned $?"
    fi

    for p in "${LEGACY_DAEMONS[@]}"; do [[ -f "$p" ]] && rm -f "$p"; done
    if [[ -d "$LEGACY_APP" ]]; then
        log "Removing $LEGACY_APP"
        rm -rf "$LEGACY_APP"
    fi
    [[ -L /usr/local/bin/banyanproxy ]] && rm -f /usr/local/bin/banyanproxy
    /usr/sbin/pkgutil --forget com.banyan.app >/dev/null 2>&1

    # Per-user launch agents from 3.x
    for home in /Users/*; do
        local agent="${home}/Library/LaunchAgents/com.banyan.banyanapp.launch.plist"
        [[ -f "$agent" ]] && rm -f "$agent"
    done
    return 0
}


################################################################################
# Config, download, install, stage, start

MY_USER=""
MY_EMAIL=""
get_user_email() {
    if [[ "$MULTI_USER" != true ]]; then
        # for a single user device, assumes user and email are set in a custom plist file deployed via Device Manager
        # (you may instead use a different technique, like: https://github.com/pbowden-msft/SignInHelper)
        if [[ -e "$USERINFO_PATH" ]]; then
            log "Extracting user email from: $USERINFO_PATH"
            MY_USER=$( defaults read "${USERINFO_PATH}" "${USERINFO_USER_VAR}" )
            MY_EMAIL=$( defaults read "${USERINFO_PATH}" "${USERINFO_EMAIL_VAR}" )
        fi
    fi

    log "Installing for user with name: $MY_USER"
    log "Installing for user with email: $MY_EMAIL"
    if [[ -z "$MY_EMAIL" ]]; then
        log "No user specified - device certificate will be issued to the default **STAGED USER**"
    fi
}

create_config() {
    log "Creating mdm-config json file"
    mkdir -p "$global_config_dir"

    mdm_config_json='{
        "mdm_invite_code": '"\"${INVITE_CODE}\""',
        "mdm_deploy_user": '"\"${MY_USER}\""',
        "mdm_deploy_email": '"\"${MY_EMAIL}\""',
        "mdm_device_ownership": '"\"${DEVICE_OWNERSHIP}\""',
        "mdm_ca_certs_preinstalled": '"${CA_CERTS_PREINSTALLED}"',
        "mdm_skip_cert_suppression": '"${SKIP_CERT_SUPPRESSION}"',
        "mdm_present": '"\"${IS_MANAGED_DEVICE}\""',
        "mdm_vendor_name": '"\"${DEVICE_MANAGER_NAME}\""',
        "mdm_hide_services": '"${HIDE_SERVICES}"',
        "mdm_disable_quit": '"${DISABLE_QUIT}"',
        "mdm_start_at_boot": '"${START_AT_BOOT}"',
        "mdm_auto_login": '"${AUTO_LOGIN}"',
        "mdm_hide_on_start": '"${HIDE_ON_START}"',
        "mdm_disable_auto_update": '"${DISABLE_AUTO_UPDATE}"',
        "mdm_multi_org": '"${ALLOW_MULTIORG}"',
        "mdm_st_over_443": '"${ST_OVER_443}"'
    }'

    echo "$mdm_config_json" > "${global_config_file}"
}

migrate_legacy_config() {
    # A device that was zero-touch installed on 3.x keeps its mdm-config.json in /etc/banyanapp.
    # 4.x reads /etc/sonicwallcse/mdm-config.json. Keys are identical between versions.
    if [[ ! -f "$global_config_file" && -f "$legacy_config_file" ]]; then
        log "Migrating legacy mdm-config.json from $legacy_config_file"
        mkdir -p "$global_config_dir"
        cp "$legacy_config_file" "$global_config_file"
    fi
}

download_install() {
    log "Downloading installer PKG"

    # check to see if the Mac is Intel or ARM; if ARM use the native build
    arm_suffix=""
    IFS='.' read osvers_major osvers_minor osvers_dot_version <<< "$(/usr/bin/sw_vers -productVersion)"
    if [[ ${osvers_major} -ge 11 ]]; then
        processor=$(/usr/sbin/sysctl -n machdep.cpu.brand_string | grep -o "Intel")
        if [[ -z "$processor" ]]; then
            log "Detected ARM processor"
            arm_suffix="-arm64"
        fi
    fi

    full_version="${APP_VERSION}${arm_suffix}"
    dl_file="${tmp_dir}/sonicwallcse-${full_version}.pkg"

    if ! curl -fsL "https://www.banyanops.com/app/releases/sonicwallcse-${full_version}.pkg" -o "${dl_file}"; then
        fail "Failed to download installer PKG for ${full_version}"
    fi
    [[ -s "$dl_file" ]] || fail "Downloaded PKG is empty: $dl_file"

    if [[ "$VERIFY_SIGNATURE" == true ]]; then
        sig=$( /usr/sbin/pkgutil --check-signature "$dl_file" 2>&1 )
        if ! echo "$sig" | grep -q "signed by a developer certificate issued by Apple" || ! echo "$sig" | grep -qiE "SonicWall|Banyan"; then
            fail "Installer signature check failed: $sig"
        fi
        log "Installer signature valid"
    fi

    log "Run installer"
    if ! SKIP_LAUNCH=1 /usr/sbin/installer -pkg "${dl_file}" -target /; then
        fail "installer returned an error"
    fi
    sleep 3
}

stage() {
    log "Running staged deployment"
    "$CSE_ADMIN" stage --key="$DEPLOYMENT_KEY"
    local rc=$?
    [[ $rc -ne 0 ]] && fail "Error during staged deployment (exit code $rc)"
    sleep 3
    log "Staged deployment done. Have the user start the SonicWall Cloud Secure Edge app to complete registration."
}

verify_install() {
    local v
    v=$(installed_version)
    [[ -d "$CSE_APP" ]] || fail "Install verification failed: $CSE_APP not found"
    [[ "$v" == "$APP_VERSION" ]] || fail "Install verification failed: installed version is '$v', expected $APP_VERSION"
    daemons_healthy || fail "Install verification failed: one or more launch daemons are missing"
    load_daemons
    legacy_present && log "WARNING: legacy Banyan components are still present"
    log "Verified: SonicWall Cloud Secure Edge $APP_VERSION installed, daemons present"
}

start_app() {
    if [[ -z "$logged_on_user" ]]; then
        log "No console user; the app will start at next login"
        return 0
    fi
    log "Starting the SonicWall Cloud Secure Edge app as: $logged_on_user"
    sudo -H -u "${logged_on_user}" open "$CSE_APP"
    sleep 5
}


################################################################################
# Main

current_version=$(installed_version)
if [[ -n "$current_version" ]]; then log "Existing install: SonicWall Cloud Secure Edge $current_version"; fi
if legacy_present; then log "Existing install: legacy Banyan 3.x components present"; fi

if [[ "$current_version" == "$APP_VERSION" ]] && ! legacy_present && daemons_healthy && [[ "$FORCE_REINSTALL" != true ]]; then
    log "Device is already clean and at $APP_VERSION. Nothing to do."
    load_daemons
    if ! $UPGRADE_FLOW && [[ ! -f "$global_config_file" ]]; then
        log "mdm-config.json missing; writing it"
        get_user_email
        create_config
    fi
    exit 0
fi

stop_app

if [[ "$REMOVE_LEGACY" == true ]]; then
    remove_legacy
elif legacy_present; then
    log "WARNING: legacy install present but REMOVE_LEGACY is false; the 4.x package will remove Banyan.app itself"
fi

if $UPGRADE_FLOW; then
    migrate_legacy_config
    download_install
    verify_install
    start_app
else
    get_user_email
    create_config
    download_install
    stage
    create_config
    verify_install
    start_app
fi

rm -f "$dl_file"
log "Done"
exit 0
