#!/bin/sh
# 切档链路的子进程数量基准 (v3.0)
#
# 目的: 用可复现的数字证明"切一次档要起多少次子进程"。
#   Windows/Git-Bash 上 fork 一次约 10~50ms, 真机约 1~3ms;
#   几十次 fork 叠起来就是用户能感觉到的"切档迟滞"。
#
# 做法: 把 /sys 前缀映射到临时目录, 用同名 shell 函数包住所有外部命令并计数,
#       在同一套假 sysfs 上分别跑「v2.3 旧实现」和「当前实现」, 对比数字。
# 注意: /system/bin/log 在测试机上不存在, 两边都一样不计入(线上每次日志会多 1 次 exec)。
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
NEW="$ROOT/Falling-MT6991"
OLDZIP="$ROOT/release/Falling-MT6991-v2.3.0.zip"
T=/tmp/pf

rm -rf "$T"; mkdir -p "$T"

# ---------- 构造一套假 sysfs ----------
build_tree() {
  d="$1"
  mkdir -p "$d/config/runtime" "$d/config/profiles"
  for p in 0 4 7; do
    mkdir -p "$d/sys/devices/system/cpu/cpufreq/policy$p/sugov_ext"
    base="$d/sys/devices/system/cpu/cpufreq/policy$p"
    printf 'schedutil\n' > "$base/scaling_governor"
    printf '500000\n'    > "$base/scaling_min_freq"
    printf '3730000\n'   > "$base/scaling_max_freq"
    printf '500\n'       > "$base/sugov_ext/up_rate_limit_us"
    printf '20000\n'     > "$base/sugov_ext/down_rate_limit_us"
  done
  mkdir -p "$d/sys/module/ged/parameters" "$d/sys/kernel/cm_mgr" \
           "$d/sys/module/mtk_c2ps/parameters"
  for f in gpu_cust_upbound_freq gpu_cust_boost_freq boost_gpu_enable ged_boost_enable; do
    printf '0\n' > "$d/sys/module/ged/parameters/$f"
  done
  printf '0\n' > "$d/sys/kernel/cm_mgr/dbg_cm_mgr"
  printf 'Y\n' > "$d/sys/module/mtk_c2ps/parameters/c2ps_um_mode_on"

  cat > "$d/config/device.conf" <<'EOF'
N_POLICY=3
POLICY0_FREQS=500000 1000000 1500000 2400000
POLICY0_GOVS=schedutil sugov_ext performance powersave
POLICY1_FREQS=500000 1000000 2000000 3300000
POLICY1_GOVS=schedutil sugov_ext performance powersave
POLICY2_FREQS=1000000 2000000 3000000 3600000 3730000
POLICY2_GOVS=schedutil sugov_ext performance powersave
GPU_DEV=
EOF
  cat > "$d/config/profiles/balanced.conf" <<'EOF'
[CPU]
GOVERNOR=sugov_ext sugov_ext sugov_ext
MAXFREQ=2400000 3300000 3600000
UP_RATE=800 800 800
DOWN_RATE=6000 10 10
[GPU]
DEVFREQ_GOVERNOR=dummy
GPU_UPBOUND=1508000
GPU_BOOST=338000
GPU_BOOST_ENABLE=0
[CM]
CM_PERF_MODE_ENABLE=1
CM_PERF_CEILING_OPP=0
CM_DRAM_OPP_CEILING=-1
[C2PS]
C2PS_UM_MODE=Y
EOF
}

# ---------- 生成被测实现 ----------
prep() {  # $1=源lib目录 $2=目标树
  src="$1"; dst="$2"
  mkdir -p "$dst/lib"
  for f in "$src"/*.sh; do
    sed -e "s#/sys/#$dst/sys/#g" \
        -e "s#/proc/#$dst/proc/#g" \
        "$f" > "$dst/lib/$(basename "$f")"
  done
  build_tree "$dst"
}

prep "$NEW/lib" "$T/new"

if command -v python >/dev/null 2>&1 && [ -f "$OLDZIP" ]; then
  python - "$OLDZIP" "$T/oldlib" <<'PY' 2>/dev/null
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1]); out = sys.argv[2]
os.makedirs(out, exist_ok=True)
for n in z.namelist():
    if n.startswith('lib/') and n.endswith('.sh'):
        open(os.path.join(out, os.path.basename(n)), 'wb').write(z.read(n))
PY
  [ -d "$T/oldlib" ] && [ -f "$T/oldlib/common.sh" ] && prep "$T/oldlib" "$T/old"
fi

# ---------- 计数执行器 ----------
cat > "$T/bench.sh" <<'EOF'
DIR=$1
CNT="$DIR/cnt.tmp"
: > "$CNT"
# 计数器必须落文件: $(date ...) 这类命令替换在子 shell 里执行,
# 变量自增传不回来, 只有写文件才能跨子 shell 统计。
for c in cat grep sed awk ls stat date tail wc tr cut head mkdir chmod chown rm mv basename dirname; do
  eval "$c() { echo x >> \"\$CNT\"; command $c \"\$@\"; }"
done
export MODDIR="$DIR" PMK_CONFIG_DIR="$DIR/config" PMK_DATA_DIR="$DIR" PMK_LOG_FILE="$DIR/log.txt"
. "$DIR/lib/common.sh" 2>/dev/null || exit 3
. "$DIR/lib/governor.sh" 2>/dev/null || exit 3
unlock_cpufreq() { :; }        # 权限已解锁是稳态前提(开机解锁一次, 之后每次切档都跳过)
: > "$CNT"
apply_profile balanced >/dev/null 2>&1
arc=$?
echo "first $(wc -l < "$CNT") rc=$arc"
: > "$CNT"
apply_profile balanced >/dev/null 2>&1
echo "repeat $(wc -l < "$CNT")"
EOF

bench() {
  label="$1"; dir="$2"
  [ -f "$dir/lib/governor.sh" ] || { echo "$label: 跳过(无实现)"; return 0; }
  out=$(bash "$T/bench.sh" "$dir" 2>/dev/null)
  f=$(printf '%s\n' "$out" | sed -n 's/^first //p')
  r=$(printf '%s\n' "$out" | sed -n 's/^repeat //p')
  [ -n "${f:-}" ] || { echo "$label: 执行失败"; return 0; }
  printf '%-10s 首次切档 %3s 次子进程 | 同档重申 %3s 次\n' "$label" "$f" "$r"
}

echo "=== 切档链路子进程计数(假 sysfs, 同一份档位配置) ==="
bench "v3.0 新" "$T/new"
echo
echo "=== 静态对比: 两个版本在切档路径里会产生子进程的写法 ==="
stat_count() {
  f="$1"; label="$2"
  [ -f "$f" ] || { echo "$label: 缺失"; return 0; }
  d=$(grep -c '\$(' "$f")
  b=$(grep -c '`' "$f")
  p=$(grep -c '| *\(grep\|sed\|tr\|awk\|cut\|head\|tail\|wc\)' "$f")
  a=$(grep -c 'awk ' "$f")
  l=$(grep -c '^ *\(ls\|cat\|stat\|mkdir\) ' "$f")
  printf '%-10s 命令替换 %3s | 管道 %3s | awk行 %2s | 直接 ls/cat/stat/mkdir %2s\n' \
    "$label" "$((d + b))" "$p" "$a" "$l"
}
if [ -f "$T/oldlib/common.sh" ]; then
  cat "$T/oldlib/common.sh" "$T/oldlib/governor.sh" > "$T/old_all.sh" 2>/dev/null
  cat "$NEW/lib/common.sh" "$NEW/lib/governor.sh" > "$T/new_all.sh"
  stat_count "$T/old_all.sh" "v2.3 旧"
  stat_count "$T/new_all.sh" "v3.0 新"
else
  echo "(没找到 v2.3 的 lib 快照, 跳过静态对比)"
fi
echo
echo "说明: 上面计数只含 common.sh + governor.sh; 外层 apply.sh 调 sched.sh 与 io.sh"
echo "      各 1 个 sh 进程(共 2 次), 两版相同。"
echo "      旧实现在本机跑不通(管道写法会卡住), 所以只做静态对比; 新实现可实跑, 数字见上。"
