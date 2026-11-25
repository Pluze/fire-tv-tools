#!/usr/bin/env bash
set -eu

usage() {
    cat <<'EOF'
Usage: fire-tv-tcl55f35.sh [status|apply|restore] TV_HOST[:PORT]

  status   Show the TV's current settings. This is the default.
  apply    Disable the 12 listed apps and turn off the three animation scales.
  restore  Return the listed apps to their default enabled state and restore
           the animation settings recorded before the change.

Pass your TV's address or set FIRE_TV_ADDRESS. The default port is 5555.
ADB debugging must be enabled on the TV, and the TV may ask you to authorize
this computer. Set ADB to an alternate adb executable path if needed.
EOF
}

action=${1:-status}
case "$action" in
    -h|--help) usage; exit 0 ;;
    status|apply|restore) ;;
    *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 2 ]; then
    usage >&2
    exit 2
fi

target=${2:-${FIRE_TV_ADDRESS:-}}
if [ -z "$target" ]; then
    printf 'Pass the TV address or set FIRE_TV_ADDRESS.\n' >&2
    exit 2
fi
if ! [[ "$target" =~ ^[[:alnum:]][[:alnum:].-]*(:[0-9]+)?$ ]]; then
    printf 'Invalid TV address: %s\n' "$target" >&2
    exit 2
fi
case "$target" in
    *:*) ;;
    *) target="$target:5555" ;;
esac

adb_bin=${ADB:-adb}
if ! command -v "$adb_bin" >/dev/null 2>&1; then
    printf 'Cannot find adb. Set ADB to its executable path.\n' >&2
    exit 2
fi

state=$("$adb_bin" -s "$target" get-state 2>/dev/null || true)
if [ "$state" != device ]; then
    if [ "$state" = offline ]; then
        "$adb_bin" disconnect "$target" >/dev/null 2>&1 || true
    fi
    "$adb_bin" connect "$target" >&2 || true
    if [ "$("$adb_bin" -s "$target" get-state 2>/dev/null || true)" != device ]; then
        printf 'ADB is not ready. Allow debugging on the TV, then rerun.\n' >&2
        exit 1
    fi
fi

"$adb_bin" -s "$target" shell -T sh -s "$action" <<'TV_SCRIPT'
set -eu
action=$1
model=$(getprop ro.product.model)
if [ "$model" != AFTDEC012E ]; then
    printf 'Unexpected Android model: %s. Expected AFTDEC012E (TCL 55F35).\n' "$model" >&2
    exit 1
fi

packages='com.amazon.bueller.music
com.amazon.firetv.youtube
com.amazon.tv.livetv
com.espn.gtv
com.estrongs.android.pop
com.nbcuni.com.nbcsports.liveextra.firetv
com.netflix.ninja
com.onemainstream.nbcunivers.android
com.plexapp.android
com.tamu.tv
com.tcl.tv.plus
group.ctv.TEXASAMUNIVERSITY'
animation_keys='window_animation_scale transition_animation_scale animator_duration_scale'

installed=$(pm list packages --user 0)
disabled=$(pm list packages -d --user 0)
has_package() {
    printf '%s\n' "$1" | grep -Fqx "package:$2"
}

case "$action" in
    apply)
        for package in $packages; do
            if has_package "$installed" "$package" && ! has_package "$disabled" "$package"; then
                pm disable-user --user 0 "$package"
            fi
        done
        for setting in $animation_keys; do
            settings put global "$setting" 0
        done
        ;;
    restore)
        for package in $packages; do
            if has_package "$disabled" "$package"; then
                pm default-state --user 0 "$package"
            fi
        done
        settings put global window_animation_scale 1.0
        settings put global transition_animation_scale 1.0
        settings delete global animator_duration_scale >/dev/null
        ;;
esac

disabled=$(pm list packages -d --user 0)
enabled=$(pm list packages -e --user 0)
failed=0
printf '\nManaged apps\n'
for package in $packages; do
    if ! has_package "$installed" "$package"; then
        state=not-installed
    elif has_package "$disabled" "$package"; then
        state=disabled
        if [ "$action" = restore ]; then failed=1; fi
    else
        state=enabled
        if [ "$action" = apply ]; then failed=1; fi
    fi
    printf '  %-43s %s\n' "$package" "$state"
done

printf '\nSystem animation scales\n'
for setting in $animation_keys; do
    value=$(settings get global "$setting")
    printf '  %-43s %s\n' "$setting" "$value"
    case "$action:$setting:$value" in
        status:*|apply:*:0|restore:animator_duration_scale:null) ;;
        restore:window_animation_scale:1.0|restore:transition_animation_scale:1.0) ;;
        *) failed=1 ;;
    esac
done

printf '\nCore components\n'
for package in com.apple.airplay.amazon.airplay com.mediatek.tis; do
    if has_package "$enabled" "$package"; then
        state=enabled
    else
        state=check-required
        failed=1
    fi
    printf '  %-43s %s\n' "$package" "$state"
done
if [ "$failed" -ne 0 ]; then
    printf '\nOne or more settings require attention.\n' >&2
    exit 1
fi
TV_SCRIPT
