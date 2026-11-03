#!/system/bin/sh
# Read existing app-owned encrypted preferences only. Never send vehicle requests.
set -eu
umask 077
BASE=/data/adb/bmw-reareye-native-v2
PKG=de.bmw.connected.mobile20.cn
DATA=/data/user/0/$PKG
DIAG=$BASE/auth_diag.txt
printf 'SYNC_STAGE=preflight\n' > "$DIAG"
note() { printf '%s\n' "$1" >> "$DIAG"; }
finish() { if [ "$1" != READING ]; then note "AUTH_RESULT=$1"; fi; printf '%s' "$1" > "$BASE/auth_state.new"; mv "$BASE/auth_state.new" "$BASE/auth_state"; }
on_exit() {
    code=$?
    note "SCRIPT_EXIT=$code"
    if [ "$(cat "$BASE/auth_state" 2>/dev/null)" = READING ]; then finish SYNC_FAILED; fi
}
trap on_exit EXIT
trap 'finish SYNC_TIMEOUT; exit 1' HUP INT TERM
finish READING
if ! /system/bin/dumpsys package "$PKG" > "$BASE/package_info.txt" 2>/dev/null; then finish PACKAGE_INFO_UNAVAILABLE; exit 0; fi
if ! grep -Eq 'versionName=6[.]9[.]0([[:space:]]|$)' "$BASE/package_info.txt"; then finish VERSION_UNSUPPORTED; exit 0; fi
if ! grep -Eq 'versionCode=54521([[:space:]]|$)' "$BASE/package_info.txt"; then finish VERSION_UNSUPPORTED; exit 0; fi
if ! ( : < "$DATA/shared_prefs/FlutterSecureStorage.xml" ) 2>/dev/null; then
    DATA=/data/data/$PKG
fi
if ! ( : < "$DATA/shared_prefs/FlutterSecureStorage.xml" ) 2>/dev/null; then finish APP_DATA_UNREADABLE; exit 0; fi
for key in __androidx_security_crypto_encrypted_prefs_key_keyset__ __androidx_security_crypto_encrypted_prefs_value_keyset__; do
    if ! grep -Fq "$key" "$DATA/shared_prefs/FlutterSecureStorage.xml"; then finish KEYSET_MISSING; exit 0; fi
done
UID_BMW=$(stat -c %u "$DATA")
case "$UID_BMW" in ''|*[!0-9]*) finish UID_UNAVAILABLE; exit 0;; esac
if [ "$UID_BMW" -lt 10000 ] || [ "$UID_BMW" -ge 100000 ]; then finish UID_UNAVAILABLE; exit 0; fi
note "APP_UID=$UID_BMW"
CP=__DEX_PATH__
APK_FIRST=
APK_COUNT=0
note SYNC_STAGE=package_path
# PackageManager CLI can fail independently of dumpsys. Prefer the already-verified
# package's codePath, then discover only its base/split APKs in that exact directory.
CODE_DIR=$(sed -n 's/^[[:space:]]*codePath=//p' "$BASE/package_info.txt" | head -n 1 | tr -d '\r')
case "$CODE_DIR" in /data/app/*)
    case "$CODE_DIR" in *[!a-zA-Z0-9_./:=+~@-]*|*/../*) CODE_DIR=;; esac
    ;;
    *) CODE_DIR=;;
esac
: > "$BASE/apks.txt"
if [ -n "$CODE_DIR" ]; then
    for apk in "$CODE_DIR/base.apk" "$CODE_DIR"/split_*.apk; do
        if ( : < "$apk" ) 2>/dev/null; then printf 'package:%s\n' "$apk" >> "$BASE/apks.txt"; fi
    done
    if [ -s "$BASE/apks.txt" ]; then note PACKAGE_SOURCE=DUMPSYS_DIRECTORY; fi
fi
if [ ! -s "$BASE/apks.txt" ]; then
    query_code=0
    /system/bin/cmd package path --user 0 "$PKG" > "$BASE/apks.txt" 2>/dev/null || query_code=$?
    note "CMD_PATH_EXIT=$query_code"
    if [ "$query_code" = 0 ] && grep -q '^package:/data/app/.*[.]apk' "$BASE/apks.txt"; then note PACKAGE_SOURCE=CMD_PACKAGE
    else
        query_code=0
        /system/bin/pm path --user 0 "$PKG" > "$BASE/apks.txt" 2>/dev/null || query_code=$?
        note "PM_PATH_EXIT=$query_code"
        if [ "$query_code" = 0 ]; then note PACKAGE_SOURCE=PM; fi
    fi
fi
tr -d '\r' < "$BASE/apks.txt" > "$BASE/apks_clean.txt"
while IFS= read -r line; do
    case "$line" in package:/data/app/*.apk)
        case "$line" in *[!a-zA-Z0-9_./:=+~@-]*|*/../*) continue;; esac
        CP="$CP:${line#package:}"
        APK_COUNT=$((APK_COUNT + 1))
        if [ -z "$APK_FIRST" ]; then APK_FIRST=${line#package:}; fi
    ;; esac
done < "$BASE/apks_clean.txt"
note "APK_COUNT=$APK_COUNT"
if [ -z "$APK_FIRST" ]; then finish APK_PATH_UNAVAILABLE; exit 0; fi
# Package paths are obtained from PackageManager, with a strict shell character allowlist.
case "$CP" in *[!a-zA-Z0-9_./:=+~@-]*) finish APK_PATH_UNAVAILABLE; exit 0;; esac
note SYNC_STAGE=client_metadata
# Optional display/client metadata must never abort local credential extraction.
if ! /system/bin/getprop ro.build.id > "$BASE/build.txt" 2>/dev/null; then printf unknown > "$BASE/build.txt"; fi
sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' "$BASE/package_info.txt" | head -n 1 > "$BASE/version.txt" || true
note SYNC_STAGE=vehicle_cache
vehicle=skip
if ( : < "$DATA/shared_prefs/VehicleDataStorage.xml" ) 2>/dev/null &&
   grep -Fq __androidx_security_crypto_encrypted_prefs_key_keyset__ "$DATA/shared_prefs/VehicleDataStorage.xml" &&
   grep -Fq __androidx_security_crypto_encrypted_prefs_value_keyset__ "$DATA/shared_prefs/VehicleDataStorage.xml"; then
    vehicle=vehicle
fi
note 'SYNC_STAGE=app_identity'
# Keep the global mount namespace for the second su as well. KernelSU supports -M.
# Emit only numeric identity/access flags before starting the same readonly helper.
inner="unset LD_PRELOAD LD_LIBRARY_PATH
actual_uid=\$(id -u)
printf 'BMW_HELPER_UID:%s\\n' \"\$actual_uid\"
if [ \"\$actual_uid\" != '$UID_BMW' ]; then printf 'BMW_ACCESS:WRONG_UID\\n'; exit 93; fi
if ! ( : < '$DATA/shared_prefs/FlutterSecureStorage.xml' ) 2>/dev/null; then printf 'BMW_ACCESS:PREF_UNREADABLE\\n'; exit 94; fi
if ! ( : < '__DEX_PATH__' ) 2>/dev/null; then printf 'BMW_ACCESS:DEX_UNREADABLE\\n'; exit 95; fi
if ! ( : < '$APK_FIRST' ) 2>/dev/null; then printf 'BMW_ACCESS:APK_UNREADABLE\\n'; exit 96; fi
printf 'BMW_ACCESS:OK\\n'
CLASSPATH='$CP' /system/bin/app_process /system/bin local.bmw.tokenreader.Main $vehicle"
code=0
/system/bin/timeout 40 su -M "$UID_BMW" -c "$inner" > "$BASE/auth.raw.new" 2> "$BASE/auth.stderr" || code=$?
note "HELPER_EXIT=$code"
chmod 600 "$BASE/auth.raw.new"
grep -E '^BMW_HELPER_UID:[0-9]+$|^BMW_ACCESS:(OK|WRONG_UID|PREF_UNREADABLE|DEX_UNREADABLE|APK_UNREADABLE)$' "$BASE/auth.raw.new" >> "$DIAG" || true
grep -E '^BMW_STAGE:(context|application_context_wrapper|provider_check|provider_install|key_store_instance|key_store_load|existing_key_check|encrypted_preferences|vehicle_cache_unavailable)$' "$BASE/auth.raw.new" | tail -n 1 >> "$DIAG" || true
grep -E '^(BMW_ERROR|BMW_CAUSE):([A-Za-z_$][A-Za-z0-9_$]*[.])+[A-Za-z_$][A-Za-z0-9_$]*(Exception|Error)$|^BMW_ERROR:(EXISTING_KEY_UNAVAILABLE|NO_ACCESS_TOKEN_VALUE)$' "$BASE/auth.raw.new" | head -n 2 >> "$DIAG" || true
# Native stderr stays private. Report known categories, never the captured text.
for signature in ClassNotFoundException NoClassDefFoundError VerifyError SecurityException 'Permission denied' 'not found' 'CANNOT LINK EXECUTABLE'; do
    if grep -Fq "$signature" "$BASE/auth.stderr"; then
        case "$signature" in
            'Permission denied') note NATIVE_ERROR=PERMISSION_DENIED;;
            'not found') note NATIVE_ERROR=EXECUTABLE_NOT_FOUND;;
            'CANNOT LINK EXECUTABLE') note NATIVE_ERROR=LINKER_FAILURE;;
            *) note "NATIVE_ERROR=$signature";;
        esac
    fi
done
promoted=0
if [ "$code" = 0 ] && grep -Fq 'BMW_TOKEN_JSON:' "$BASE/auth.raw.new"; then
    mv "$BASE/auth.raw.new" "$BASE/auth.raw"
    promoted=1
else
    rm -f "$BASE/auth.raw.new"
fi
if [ "$code" = 124 ]; then finish SYNC_TIMEOUT
elif [ "$promoted" = 1 ]; then finish SYNC_COMPLETE
else finish SYNC_FAILED
fi
