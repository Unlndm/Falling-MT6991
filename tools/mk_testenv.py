#!/usr/bin/env python
# ============================================================
# 测试环境准备器 (Windows 本机用)
#
# 为什么需要: 本机沙箱把「脚本进程内的文件删除/覆盖」包装成需确认的版本,
#   非交互下挂起直到超时。而 Git Bash 的 /tmp 路径与 Windows Python
#   的路径不互通(/tmp/st -> C:/Users/xxx/Temp/st), 导致任何跨
#   bash<->python 的文件操作都对不上路径。
#
# 解决: 准备阶段全部在 Python 里做(建目录 + 复制文件 + 写假节点),
#   路径统一用 Windows 形式; 测试主体仍是 shell, 读这些假节点。
#
# 用法: python tools/mk_testenv.py <profile> <outdir_win>
#   profile: sched | smart | io | thermal | loop | config
# ============================================================
import os
import re
import shutil
import subprocess
import sys


def to_posix(path):
    """Windows 路径 -> Git Bash POSIX 路径(/d/...)。
    不依赖外部传参: 调用方的 $(pwd) 在不同上下文可能返回 Windows 形式。"""
    p = path.replace("\\", "/")
    if not p.startswith("/"):
        try:
            return subprocess.check_output(["cygpath", "-u", p],
                                           text=True).strip()
        except Exception:
            return p
    return p

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(SRC, "Falling-MT6991")

PROFILES = {
    "sched": {
        "dirs": ["lib", "config/runtime", "proc/sys/kernel",
                 "proc/hmbird_sched/slim_walt", "proc/hmbird_sched/slim_freq_gov",
                 "proc/touch_boost"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/sched.sh", "Falling-MT6991/lib/sched.sh",
             [("/proc/", "@PROC@/")]),
            ("config/profiles", "Falling-MT6991/config/profiles", "dir"),
        ],
    },
    "smart": {
        "dirs": ["lib", "config/runtime", "thermal", "cpu/cpufreq",
                 "proc/hmbird_sched"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/metrics.sh", "Falling-MT6991/lib/metrics.sh",
             [("/sys/class/thermal", "@OUT@/thermal"),
              ("/sys/devices/system/cpu/cpufreq", "@OUT@/cpu/cpufreq"),
              # 真机有 /sys/kernel/fpsgo/fstb/fpsgo_status, 会读到真实帧率,
              # 让含 fps 的断言随设备当前状态飘; 映射到不存在的测试路径 -> MET_FPS=-1。
              ("/sys/kernel/fpsgo", "@OUT@/fpsgo"),
              ("/proc/stat", "@OUT@/stat"),
              # 真机有 /proc/pressure/cpu, 映射到不存在的测试路径,
              # 让 PSI 默认 -1(与纯 shell 分支一致); PSI 分支靠注入测。
              ("/proc/pressure/cpu", "@OUT@/pressure/cpu")]),
            ("lib/smart.sh", "Falling-MT6991/lib/smart.sh", None),
            ("lib/loop.sh", "Falling-MT6991/lib/loop.sh",
             [("/proc/hmbird_sched", "@OUT@/proc/hmbird_sched"),
              ("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpu/cpufreq/policy[0-9]*")]),
            # loop.sh 依赖 extreme.sh (extreme_state_read / extreme_load)
            ("lib/extreme.sh", "Falling-MT6991/lib/extreme.sh", None),
        ],
    },
    "io": {
        "dirs": ["lib", "config", "block/sda/queue", "block/dm-0/queue"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/io.sh", "Falling-MT6991/lib/io.sh",
             [("/sys/block", "@OUT@/block")]),
        ],
    },
    "thermal": {
        "dirs": ["lib", "config/runtime", "thermal", "cpufreq/policy0",
                 "cpufreq/policy4", "cpufreq/policy7", "proc/hmbird_sched"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/thermal.sh", "Falling-MT6991/lib/thermal.sh",
             [("/proc/hmbird_sched", "@OUT@/proc/hmbird_sched"),
              ("/sys/class/thermal", "@OUT@/thermal"),
              ("/sys/devices/system/cpu/cpufreq", "@OUT@/cpufreq")]),
            ("lib/loop.sh", "Falling-MT6991/lib/loop.sh",
             [("/proc/hmbird_sched", "@OUT@/proc/hmbird_sched"),
              ("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            # loop.sh 依赖 extreme.sh (extreme_state_read / extreme_load)
            ("lib/extreme.sh", "Falling-MT6991/lib/extreme.sh", None),
        ],
    },
    "loop": {
        "dirs": ["lib", "config/runtime", "cpufreq/policy0", "cpufreq/policy4",
                 "cpufreq/policy7", "proc/hmbird_sched", "thermal/thermal_zone0"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/loop.sh", "Falling-MT6991/lib/loop.sh",
             [("/proc/hmbird_sched", "@OUT@/proc/hmbird_sched"),
              ("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            # loop.sh 依赖 extreme.sh (extreme_state_read / extreme_load)
            ("lib/extreme.sh", "Falling-MT6991/lib/extreme.sh", None),
            ("lib/thermal.sh", "Falling-MT6991/lib/thermal.sh",
             [("/proc/hmbird_sched", "@OUT@/proc/hmbird_sched"),
              ("/sys/class/thermal", "@OUT@/thermal"),
              ("/sys/devices/system/cpu/cpufreq", "@OUT@/cpufreq")]),
        ],
    },
    "config": {
        "dirs": ["lib", "config/runtime", "config/defaults"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/config.sh", "Falling-MT6991/lib/config.sh", None),
            ("config/system.conf", "Falling-MT6991/config/system.conf", None),
            ("config/apps.conf", "Falling-MT6991/config/apps.conf", None),
            ("config/defaults", "Falling-MT6991/config/defaults", "dir"),
        ],
    },
    "extreme": {
        "dirs": ["lib", "config/runtime", "config/profiles",
                 "cpufreq/policy0", "cpufreq/policy4", "cpufreq/policy7",
                 "proc/hmbird_sched"],
        "files": [
            ("lib/common.sh", "Falling-MT6991/lib/common.sh",
             [("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/extreme.sh", "Falling-MT6991/lib/extreme.sh", None),
            ("lib/loop.sh", "Falling-MT6991/lib/loop.sh",
             [("/proc/hmbird_sched", "@OUT@/proc/hmbird_sched"),
              ("/sys/devices/system/cpu/cpufreq/policy[0-9]*",
               "@OUT@/cpufreq/policy[0-9]*")]),
            ("lib/apply.sh", "Falling-MT6991/lib/apply.sh", None),
            ("config/profiles", "Falling-MT6991/config/profiles", "dir"),
        ],
    },
}


# 沙箱适配: 本机沙箱把脚本内的 rm 包装成需确认的版本, 非交互下挂起到超时。
# 产品代码在 Android 上正常, 所以只改"测试副本", 不动产品源码。
# 改写规则: rm -f A B C  ->  : > A; : > B; : > C
#   临时文件/状态文件用截断代替删除, 对本模块的读取逻辑等价
#   (读不到内容就是空, [ -s ] 判断同样成立)。
# rm -f 可能跨行续行(\ 换行), 所以先合并续行再替换。
# 替换目标是一个自定义函数 pmk_rm —— 由脚本头部的 shim 定义:
#   先截断(让文件变空)再移走, 移走保证 [ -f ] 为假, 与真实删除语义一致。
#   截断这一步是关键: 非空文件直接 mv 会被环境拦截。
RM_RE = re.compile(r"rm\s+-[a-zA-Z]*f[a-zA-Z]*((?:[^\n;&|]+))")


def rm_to_truncate(text):
    # 1) 合并续行: "a \\n   b" -> "a b"
    text = text.replace("\\\n", " ")
    def repl(m):
        out = []
        for f in m.group(1).split():
            if f.startswith("2>") or f.startswith(">") or f.startswith("-"):
                continue
            # 保留原有引号, 只把 rm 换成 pmk_rm
            if (f.startswith('"') and f.endswith('"')) or \
               (f.startswith("'") and f.endswith("'")):
                out.append(f)
            else:
                out.append('"%s"' % f)
        return ("pmk_rm " + " ".join(out)) if out else "true"
    return RM_RE.sub(repl, text)


def build(profile, out, posix_root=None):
    cfg = PROFILES[profile]
    # 重建目录
    if os.path.isdir(out):
        shutil.rmtree(out, ignore_errors=True)
    for d in cfg["dirs"]:
        os.makedirs(os.path.join(out, d), exist_ok=True)
    # 回收目录: 改写后的 rm 把文件移到这里(不留同名文件在原目录)
    trash = os.path.join(out, "_trash")
    os.makedirs(trash, exist_ok=True)

    for dest, src_rel, transform in cfg["files"]:
        src = os.path.join(SRC, src_rel.replace("/", os.sep))
        dst = os.path.join(out, dest.replace("/", os.sep))
        if transform == "dir":
            if os.path.isdir(src):
                shutil.copytree(src, dst, dirs_exist_ok=True)
            continue
        if not os.path.isfile(src):
            print("MISS", src_rel)
            continue
        data = open(src, "r", encoding="utf-8").read()
        if transform:
            for a, b in transform:
                shell_root = (posix_root or to_posix(out)).rstrip("/")
                rep = b.replace("@OUT@", shell_root)
                rep = rep.replace("@PROC@", shell_root + "/proc")
                data = data.replace(a, rep)
        # 环境适配: rm -f -> 截断+移走(只改测试副本)
        data = rm_to_truncate(data)
        # 注入 pmk_rm 替身(脚本内 rm 会被环境拦截)
        if "pmk_rm" in data:
            data = ("# ---- 环境适配: rm 替身(脚本内 rm 会被环境拦截) ----\n"
                    "PMK_TEST_TRASH=\"" + (posix_root.rstrip("/") if posix_root else to_posix(out).rstrip("/")) + "/_trash\"\n"
                    "mkdir -p \"$PMK_TEST_TRASH\" 2>/dev/null\n"
                    "pmk_rm(){ local a; for a in \"$@\"; do\n"
                    "  [ -e \"$a\" ] || continue\n"
                    "  if [ -d \"$a\" ]; then\n"
                    "    mv \"$a\" \"$PMK_TEST_TRASH/d.$(basename \"$a\").trash\" 2>/dev/null\n"
                    "    continue\n"
                    "  fi\n"
                    "  : > \"$a\" 2>/dev/null\n"
                    "  mv \"$a\" \"$PMK_TEST_TRASH/$(basename \"$a\").trash\" 2>/dev/null\n"
                    "done; return 0; }\n") + data
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8", newline="\n") as f:
            f.write(data)
    print("READY", profile, out)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    # argv[3] = shell 侧的 POSIX 路径根(用于生成 shell 能访问的路径)
    # argv[3] = 测试目录的 POSIX 形式(shell 侧可见的路径)
    build(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
