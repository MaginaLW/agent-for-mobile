#!/system/bin/sh
# 只在已核实身份的合成 AVD 内执行，stdout 留在该轮私有目录。
set -eu
target=dev.magina.autofilltarget
observer=dev.magina.autofillobserver
fail() { echo "$1" >&2; exit 1; }
[ "$(getprop ro.kernel.qemu)" = 1 ] && [ "$(getprop ro.build.version.sdk)" = 36 ] || fail WRONG_AVD
[ "$(run-as "$target" cat files/origin-ready)" = 1 ] || fail TARGET_NOT_READY
entries=$(run-as "$observer" ls -1 files) || fail OBSERVER_DIRECTORY_UNREADABLE
case "
$entries
" in
    *"
origin.json
"*) fail PREEXISTING_ORIGIN ;;
esac
stamp() { echo "## $1"; cat /proc/uptime; }
windows() {
    stamp "$1-windows"
    dumpsys window -a windows
    stamp "$1-displays"
    dumpsys window -a displays
}
windows before
stamp accessibility-before
dumpsys accessibility
stamp release
run-as "$target" touch files/origin-release
attempt=0
until run-as "$observer" test -f files/origin.json; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 90 ]; then echo "ORIGIN_CALLBACK_ABSENT"; exit 1; fi
    sleep 0.05
done
stamp callback
run-as "$observer" cat files/origin.json
echo
stamp session1
dumpsys autofill
windows during
stamp session2
dumpsys autofill
stamp accessibility
dumpsys accessibility
windows after
stamp close
