#!/usr/bin/env bash
# Adapt the installed RflySim launcher to a custom PX4 source tree without
# modifying either the RflySim installation or the PX4 repository.

if [ "$#" -lt 4 ]; then
    echo "Usage: $0 <px4-source-root> <count> <first-id> <model>" >&2
    exit 2
fi

px4_source_root="$1"
shift
vendor_launcher="/mnt/d/PX4PSP/RflySimAPIs/RflySimSDK/sh/sitl_multiple_run_rfly.sh"

if [ ! -x "$px4_source_root/build/px4_sitl_default/bin/px4" ]; then
    echo "Missing PX4 SITL binary: $px4_source_root/build/px4_sitl_default/bin/px4" >&2
    exit 3
fi

if [ ! -f "$px4_source_root/ROMFS/px4fmu_common/init.d-posix/airframes/4510_tailpusher" ]; then
    echo "Missing TailPusher SITL airframe in: $px4_source_root" >&2
    exit 4
fi

if [ ! -f "$vendor_launcher" ]; then
    echo "Missing RflySim launcher: $vendor_launcher" >&2
    exit 5
fi

patched_launcher="$(mktemp)"
cleanup() {
    rm -f "$patched_launcher"
}
trap cleanup EXIT

# Current RflySim launchers derive src_path from BASH_SOURCE. Replace only
# that path bootstrap in a temporary copy so all remaining vendor logic stays
# current with the installed RflySim release.
export RFLY_CUSTOM_PX4_ROOT="$px4_source_root"
command awk '
    NR == 19 {
        print "SCRIPT_DIR=\"${RFLY_CUSTOM_PX4_ROOT}/Tools\""
        print "src_path=\"${RFLY_CUSTOM_PX4_ROOT}\""
        print "PSP_PATH_LINUX=\"$( cd \"$src_path/..\" && pwd )\""
        print "export PSP_PATH_LINUX"
        print "build_path=\"${src_path}/build/px4_sitl_default\""
        next
    }
    NR >= 20 && NR <= 24 { next }
    { print }
' "$vendor_launcher" > "$patched_launcher"

# PX4 1.15 uses an older rcS layout. Keep the vendor launcher's port and
# instance edits, but skip its newer exact-name insertion for this tree.
awk() {
    if [[ "$1" == *"RflySim: prefer the exact model name"* ]]; then
        command cat "$2"
    else
        command awk "$@"
    fi
}

pid_file="$px4_source_root/build/px4_sitl_default/rfly_parametric_uav.pids"
: > "$pid_file"

# shellcheck source=/dev/null
source "$patched_launcher" "$@"
launcher_status=$?
jobs -p > "$pid_file"

while IFS= read -r px4_pid; do
    wait "$px4_pid" || launcher_status=$?
done < "$pid_file"

exit "$launcher_status"
