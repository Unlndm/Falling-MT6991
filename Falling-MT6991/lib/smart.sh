#!/system/bin/sh
# ============================================================
# Falling-MT6991 智能调度引擎 (v3.0)
#
# 目标: 用户不选场景、不选档位、不调阈值。模块按
#       "温度 / 整机忙时 / 分簇忙时 / 帧率 / CPU 争用 / 前台应用 / 屏态" 自己决定档位。
#
# 信号全部来自 lib/metrics.sh 的一次采集(零 fork), 本文件只做算术与判定。
#
# 决策优先级(自上而下覆盖):
#   1. 息屏                 -> powersave+            (固定, 不参与评分)
#   2. 温度 >= 58°C         -> 立刻降档, 忽略驻留时间  (安全优先)
#   3. 应用策略(apps.conf)  -> 用户显式指定, 温度 < 54°C 时直接采用
#   4. 游戏(模块调度)       -> game_medium 保底, 低帧/满载升 performance
#   5. 综合评分             -> performance / balanced / powersave
#
# v3.0 相对 v2.x 的改动:
#   - 采样统一到 metrics.sh, decide 里不再有 $( ) 命令替换
#   - 新增分簇信号: 大核(prime)吃满才额外加分。整机 45% 可能是
#     "小核全满大核全闲"(瓶颈在迁移/并行度) 也可能是三簇各 45%,
#     只看整机会把前者误判成后者。不做负向扣分, 避免把"小核紧"读成"不用提频"
#   - 新增决策遥测: 换档时写 runtime/smart.trace(环形) + runtime/smart.stats(驻留秒数)
#     这是"为什么又降档了"唯一可查的证据, WebUI 调度页直接读它
#
# 防抖: 单次只跳一档; 升档要越过 enter 阈值, 降档要跌破 exit 阈值;
#       非温度原因换档需驻留 >= 20s。
#
# 参考: PELT/uutil_est 与 schedutil 的利用率->频率映射、uclamp 地板钳位、
#       帧预算反馈(util 换频率留 20% 余量)、ADPF 热余量分级(0.85/0.95 阈值)
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"
[ -f "$MODDIR/lib/metrics.sh" ] && . "$MODDIR/lib/metrics.sh"

SMART_STATE="$PMK_RUNTIME_DIR/smart.state"
SMART_CNT="$PMK_RUNTIME_DIR/smart.count"    # lowc hic since
SMART_FPSH="$PMK_RUNTIME_DIR/fps.hist"      # 最近 3 次帧率采样(去抖窗口)
SMART_EMAF="$PMK_RUNTIME_DIR/score.ema"     # 评分 EMA(抑制来回换档)
SMART_TRACE="$PMK_RUNTIME_DIR/smart.trace"  # 决策历史(环形)
SMART_STATS="$PMK_RUNTIME_DIR/smart.stats"  # 档位驻留累计秒
SMART_TRACE_MAX=240
SMART_TRACE_KEEP=120

# 评分阈值(带滞回)
SM_ENTER_PERF=62    # balanced -> performance
SM_EXIT_PERF=54     # performance -> balanced
SM_ENTER_SAVE=23    # balanced -> powersave
SM_EXIT_SAVE=39     # powersave -> balanced
SM_STAY=20          # 非温度原因的最小驻留秒数
SM_TEMP_FORCE=58000 # 强制降档温度(mC)
SM_TEMP_HINT=54000  # 高于此行应用策略不再直接采用(mC)

# ---------- 调度倾向(用户可选: 省电 / 均衡 / 性能) ----------
# 语义: 只给"综合评分"加一个固定偏置, 不锁档位。
#   save   偏置 -15: 默认分 40 -> 25, 真正空闲(busy<=12%)才掉到省电档;
#                   要 busy>=55% 才勉强够上"均衡", 升性能基本要靠大核吃满。
#   perf   偏置 +15: 默认分 40 -> 55, 有点负载(busy>=55%)就升性能;
#                   帧率有余量的 -12 会被抵消, 倾向保持高性能。
# 硬规则不受倾向影响(它们在评分之前就 return 了):
#   息屏降档 / 高温强制降档 / 应用策略直通 / 游戏保底。
SM_TEND="balance"
SM_TEND_BIAS=0
SM_TEND_TICK=0
SM_TEND_REFRESH=20   # 秒, 与守护读 game_mode 同节奏

# 读调度倾向 -> SM_TEND / SM_TEND_BIAS (零 fork; 每 20 秒才真读一次文件)
smart_load_tendency() {
  local now="${1:-0}"
  if [ "$now" -gt 0 ] 2>/dev/null && [ $((now - SM_TEND_TICK)) -lt "$SM_TEND_REFRESH" ]; then
    return 0
  fi
  SM_TEND="balance"; SM_TEND_BIAS=0
  if cfg_get tendency; then
    case "$_CFG_VAL" in
      save)  SM_TEND="save";  SM_TEND_BIAS=-15 ;;
      perf)  SM_TEND="perf";  SM_TEND_BIAS=15 ;;
      *)     SM_TEND="balance"; SM_TEND_BIAS=0 ;;
    esac
  fi
  if [ "$now" -gt 0 ] 2>/dev/null; then SM_TEND_TICK="$now"; fi
  return 0
}

# 档位文件是否存在(应用策略写错名字时不许拿去写, 否则 apply 失败刷日志)
smart_profile_ok() {
  [ -n "$1" ] || return 1
  [ -f "$PMK_CONFIG_DIR/profiles/$1.conf" ] || return 1
  return 0
}

# 温度 -> 评分修正, 结果放 SA_ADJ(不 fork)
smart_temp_adj() {
  local t="$1"
  if   [ "$t" -ge 60000 ] 2>/dev/null; then SA_ADJ=-40
  elif [ "$t" -ge 55000 ] 2>/dev/null; then SA_ADJ=-25
  elif [ "$t" -ge 50000 ] 2>/dev/null; then SA_ADJ=-12
  elif [ "$t" -gt 0 ] && [ "$t" -lt 42000 ] 2>/dev/null; then SA_ADJ=6
  else SA_ADJ=0; fi
}

# 大核(prime)忙时 -> SM_PRIME; 单簇或不支持时 -1
smart_prime_busy() {
  SM_PRIME=-1
  if [ "${MET_NCL:-0}" -ge 3 ]; then
    SM_PRIME="${MET_CL2:--1}"
  elif [ "${MET_NCL:-0}" -eq 2 ]; then
    SM_PRIME="${MET_CL1:--1}"
  fi
}

# ---------- 信号去抖 ----------
# 帧率: fpsgo_status 的 currentFPS 是"每渲染器瞬时值", 5s 一次采样只在
# 100/70/60/10/2 之间跳(渲染器增删/动画起停/旋转), 单次采样直接做
# "连续低帧 / 连续高帧"判定时, 计数会被一次抖动清零, 结果 lowc>=2 与 hic>=6
# 两条判据几乎永远凑不齐(实机 trace 里长期 lowc=0 hic=0)。
# 取最近 3 次采样的中位数参与判定; smart.state 仍写原始 fps, 方便 UI 对照。
# 读不到(-1)时清空窗口并清零计数(AGENTS: 读不到就跳过, 不保留陈旧基线)。
# 结果放 SM_FPS。
smart_fps_win() {
  local a b c v1 v2 t
  SM_FPS="$1"
  a=-1; b=-1; c=-1
  [ -f "$SMART_FPSH" ] && read -r a b c < "$SMART_FPSH" 2>/dev/null
  case "$a" in ''|*[!0-9]*) a=-1 ;; esac
  case "$b" in ''|*[!0-9]*) b=-1 ;; esac
  case "$c" in ''|*[!0-9]*) c=-1 ;; esac
  if [ "$1" = "-1" ]; then
    printf '%s %s %s\n' -1 -1 -1 > "$SMART_FPSH" 2>/dev/null
    SM_FPS=-1
    return 0
  fi
  # 窗口后移: 丢掉最旧的 a, 新样本进 c
  a="$b"; b="$c"; c="$1"
  printf '%s %s %s\n' "$a" "$b" "$c" > "$SMART_FPSH" 2>/dev/null
  if [ "$a" -lt 0 ] && [ "$b" -lt 0 ]; then
    SM_FPS="$c"
  elif [ "$a" -lt 0 ] || [ "$b" -lt 0 ]; then
    # 只有两个有效样本: 取较小值(偏保守, 宁可认为帧率还没恢复)
    if [ "$a" -lt 0 ]; then v1="$c"; else v1="$a"; fi
    if [ "$b" -lt 0 ]; then v2="$c"; else v2="$b"; fi
    [ "$v1" -lt "$v2" ] 2>/dev/null && SM_FPS="$v1" || SM_FPS="$v2"
  else
    # 三个有效样本: 排序后取中位数(a b c 此时已写入文件, 就地换位无副作用)
    if [ "$a" -gt "$b" ]; then t="$a"; a="$b"; b="$t"; fi
    if [ "$b" -gt "$c" ]; then t="$b"; b="$c"; c="$t"; fi
    if [ "$a" -gt "$b" ]; then t="$a"; a="$b"; b="$t"; fi
    SM_FPS="$b"
  fi
  return 0
}

# 评分 EMA: 单轮原始分会被一个噪声信号推着跨阈值(PSI ±12 / 帧率 ±30),
# 实机 10 分钟出现过 13 次换档。用步长 1/4 的 EMA 压掉单轮尖峰;
# 滞回阈值 / 单次只跳一档 / 20s 驻留全部保留(EMA 只喂给滞回映射)。
# 状态存 runtime/score.ema(单值); 首次运行没有基线时直接采用原始分。
# 结果放 SM_SCORE。
smart_score_ema() {
  local raw="$1" prev="" out
  [ -f "$SMART_EMAF" ] && read -r prev < "$SMART_EMAF" 2>/dev/null
  case "$prev" in
    ''|*[!0-9]*) out="$raw" ;;
    *) out=$(( (prev * 3 + raw) / 4 )) ;;
  esac
  [ "$out" -lt 0 ] 2>/dev/null && out=0
  [ "$out" -gt 100 ] 2>/dev/null && out=100
  printf '%s\n' "$out" > "$SMART_EMAF" 2>/dev/null
  SM_SCORE="$out"
  return 0
}

# ---------- 遥测 ----------
# 累加某档位驻留秒数(只在换档时调用, 不是每轮, 所以读写小文件的成本可忽略)
smart_stats_add() {
  local prof="$1" secs="$2"
  [ -n "$prof" ] || return 0
  [ "${secs:-0}" -gt 0 ] 2>/dev/null || return 0
  runtime_dir
  local k v out="" found=0
  if [ -f "$SMART_STATS" ]; then
    while IFS='=' read -r k v; do
      [ -n "$k" ] || continue
      case "$v" in ''|*[!0-9]*) v=0 ;; esac
      if [ "$k" = "$prof" ]; then
        out="$out$k=$((v + secs))
"
        found=1
      else
        out="$out$k=$v
"
      fi
    done < "$SMART_STATS"
  fi
  [ "$found" = 1 ] || out="$out$prof=$secs
"
  printf '%s' "$out" > "$SMART_STATS" 2>/dev/null
}

# 决策历史(环形): 时间 原档 新档 原因 评分 温度 整机忙时 大核忙时 帧率 争用
smart_trace() {
  local from="${1:-none}" to="${2:-}" reason="${3:-}" score="${4:-0}"
  runtime_dir
  printf '%s %s>%s %s score=%s t=%s busy=%s prime=%s fps=%s psi=%s\n' \
    "$(date '+%m-%d %H:%M:%S')" "${from:-none}" "$to" "$reason" \
    "${score:-0}" "${MET_TEMP:-0}" "${MET_BUSY:--1}" "${SM_PRIME:--1}" "${MET_FPS:--1}" "${MET_PSI:--1}" \
    >> "$SMART_TRACE" 2>/dev/null
  local n=0
  n=$(wc -l < "$SMART_TRACE" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$n" -gt "$SMART_TRACE_MAX" ]; then
    tail -n "$SMART_TRACE_KEEP" "$SMART_TRACE" > "$SMART_TRACE.t" 2>/dev/null \
      && mv -f "$SMART_TRACE.t" "$SMART_TRACE" 2>/dev/null
  fi
}

# 写状态快照(UI 只读这个文件)
smart_save() {
  local cur="$1" want="$2" score="$3" now="$4" reason="$5"
  runtime_dir
  {
    echo "profile=$want"
    echo "previous=$cur"
    echo "score=$score"
    echo "temp=${MET_TEMP:-0}"
    echo "busy=${MET_BUSY:--1}"
    echo "prime=${SM_PRIME:--1}"
    echo "cluster0=${MET_CL0:--1}"
    echo "cluster1=${MET_CL1:--1}"
    echo "cluster2=${MET_CL2:--1}"
    echo "fps=${MET_FPS:--1}"
    echo "psi=${MET_PSI:--1}"
    echo "reason=$reason"
    echo "tendency=${SM_TEND:-balance}"
    echo "updated=$now"
    echo "cores=${MET_CORES:-0}"
  } > "$SMART_STATE" 2>/dev/null
}

# 决策: smart_decide <pkg> <screen_on:0|1> <hint_profile|""> <now> [screen_off_profile] [game:0|1]
# 输出档位名; 详细原因写 runtime/smart.state
smart_decide() {
  local pkg="${1:-}" on="${2:-1}" hint="${3:-}" now="${4:-0}" soff="${5:-powersave+}" game="${6:-0}"
  runtime_dir
  local cur lowc hic since score base reason want psi psi_used fps_raw

  cur=""; lowc=0; hic=0; since=0
  if [ -f "$SMART_CNT" ]; then
    read -r lowc hic since < "$SMART_CNT" 2>/dev/null
  fi
  [ -n "$lowc" ] || lowc=0
  [ -n "$hic" ] || hic=0
  [ -n "$since" ] || since=0
  # 基线 = 当前真正生效的档位(apply.sh 写的), 不是上一轮的决策结果
  cur=""
  read -r cur < "$PMK_RUNTIME_DIR/profile.applied" 2>/dev/null
  [ -n "$cur" ] || cur=balanced

  # 调度倾向(用户选的省电/均衡/性能): 息屏分支也要写进状态快照, 所以在分支前就加载
  smart_load_tendency "$now"

  # 1. 息屏: 固定极限省电, 不参与评分(不需要采样, 省掉每轮读节点)
  if [ "$on" = "0" ]; then
    MET_TEMP=0; MET_BUSY=-1; MET_FPS=-1; MET_PSI=-1; SM_PRIME=-1
    MET_CL0=-1; MET_CL1=-1; MET_CL2=-1; MET_NCL=0
    met_cores
    # 息屏期间的帧率样本不可信, 清空去抖窗口, 亮屏后从新样本重新起算
    printf '%s %s %s\n' -1 -1 -1 > "$SMART_FPSH" 2>/dev/null
    [ "$cur" != "$soff" ] && {
      smart_stats_add "$cur" $((now - since))
      smart_trace "$cur" "$soff" "息屏"
    }
    smart_save "$cur" "$soff" 0 "$now" "息屏"
    printf '%s' "$soff"
    return 0
  fi

  # 一次采集(内部零 fork)
  # PMK_MET_READY=1 表示"本轮信号已由调用方采集好"(守护进程主进程路径),
  # 此时直接复用, 避免 met_cpu 拿刚写的基线算差值 -> busy 变 -1。
  # 其它调用路径(测试/外部脚本直接调)永远读到 0 -> 每次采新数据。
  [ "${PMK_MET_READY:-0}" = "1" ] || met_collect_reset
  met_collect
  local t="${MET_TEMP:-0}" busy="${MET_BUSY:--1}" fps psi
  fps_raw="${MET_FPS:--1}"
  # 帧率先过 3 点中位数窗口(去抖), 再进连续计数
  smart_fps_win "$fps_raw"
  fps="$SM_FPS"
  psi="${MET_PSI:--1}"
  smart_prime_busy

  # 帧率连续计数(只有数据有效才算, 用去抖后的中位数)
  # 帧率读不到时清零: 否则"上一次读到的连续低帧计数"会一直挂着,
  # 等下次有数据时立刻凑够 2 轮, 把"刚恢复"误判成"持续低帧"(AGENTS: 读不到就跳过)。
  if [ "$fps" != "-1" ]; then
    if [ "$fps" -lt 80 ] 2>/dev/null; then lowc=$((lowc + 1)); else lowc=0; fi
    if [ "$fps" -ge 97 ] 2>/dev/null; then hic=$((hic + 1)); else hic=0; fi
  else
    lowc=0; hic=0
  fi

  # 2. 温度强制降档(忽略驻留)
  if [ "$t" -ge "$SM_TEMP_FORCE" ] 2>/dev/null; then
    case "$cur" in
      performance) want=balanced ;;
      *)           want=powersave ;;
    esac
    echo "$lowc $hic $now" > "$SMART_CNT" 2>/dev/null
    [ "$want" != "$cur" ] && {
      smart_stats_add "$cur" $((now - since))
      smart_trace "$cur" "$want" "温度$((t / 1000))强制降档"
    }
    smart_save "$cur" "$want" 0 "$now" "温度 $((t / 1000))°C 强制降档"
    printf '%s' "$want"
    return 0
  fi

  # 应用策略档位不存在(拼错/档位文件被删)时丢弃, 交给自动评分; 否则 apply 每轮失败刷日志
  if [ -n "$hint" ] && ! smart_profile_ok "$hint"; then
    log_err "smart: 应用策略档位无效 '$hint' (${pkg:-?}), 已忽略"
    hint=""
  fi

  # 3. 应用策略: 用户给该 App 显式指定了档位, 温度不高时直接采用
  if [ -n "$hint" ] && { [ "$t" -lt "$SM_TEMP_HINT" ] 2>/dev/null || [ "$t" = 0 ]; }; then
    echo "$lowc $hic $now" > "$SMART_CNT" 2>/dev/null
    [ "$hint" != "$cur" ] && {
      smart_stats_add "$cur" $((now - since))
      smart_trace "$cur" "$hint" "应用策略:${pkg:-?}"
    }
    smart_save "$cur" "$hint" 0 "$now" "应用策略 ${pkg:-?}"
    printf '%s' "$hint"
    return 0
  fi

  # 4. 游戏(模块调度): game_medium 保底(升频快/上限低于性能档, 适合持续跑游戏),
  #    帧率不足或基本打满才升 performance。温度 >= 54°C 不再保底, 让评分降档。
  if [ "$game" = "1" ] && [ "$t" -lt "$SM_TEMP_HINT" ] 2>/dev/null; then
    want=game_medium
    reason="游戏(模块调度)"
    if [ "$fps" != "-1" ] && [ "$fps" -lt 60 ] 2>/dev/null; then
      want=performance; reason="游戏帧率不足, 升性能"
    elif [ "$busy" -ge 85 ] 2>/dev/null; then
      want=performance; reason="游戏满载, 升性能"
    fi
    # 升 performance 也守驻留; 回落到 game_medium 不等(降档不抖)
    if [ "$want" = performance ] && [ "$cur" != performance ] && [ "$since" -gt 0 ] && [ "$now" -gt 0 ] \
       && [ $((now - since)) -lt "$SM_STAY" ]; then
      want=game_medium; reason="游戏(模块调度)"
    fi
    [ "$want" != "$cur" ] && {
      smart_stats_add "$cur" $((now - since))
      smart_trace "$cur" "$want" "$reason"
      since="$now"
    }
    echo "$lowc $hic $since" > "$SMART_CNT" 2>/dev/null
    smart_save "$cur" "$want" 0 "$now" "$reason"
    printf '%s' "$want"
    return 0
  fi

  # 5. 综合评分
  # 基础 40; 温度修正; 整机忙时修正; 大核饱和修正; 帧率修正
  base=40
  smart_temp_adj "$t"; base=$((base + SA_ADJ))
  if [ "$busy" -ge 0 ] 2>/dev/null; then
    if   [ "$busy" -ge 85 ]; then base=$((base + 25))
    elif [ "$busy" -ge 55 ]; then base=$((base + 10))
    elif [ "$busy" -le 12 ]; then base=$((base - 18))
    fi
  fi
  # 大核吃满 = 当前上限真的不够(整机忙时看不出这一层)
  # 分档按 AGENTS 硬规则: >=50 +4 / >=70 +10 / >=90 +18。只做正向加分,
  # 小核忙不代表不需要性能, 扣分会把卡顿做出来。
  if [ "$SM_PRIME" -ge 50 ] 2>/dev/null; then
    base=$((base + 4))
    if [ "$SM_PRIME" -ge 70 ] 2>/dev/null; then
      base=$((base + 6))
      [ "$SM_PRIME" -ge 90 ] 2>/dev/null && base=$((base + 8))
    fi
  fi
  # 帧率: 连续低帧说明当前档撑不住, 连续高帧说明有余量
  if [ "$fps" != "-1" ]; then
    if [ "$fps" -lt 60 ] 2>/dev/null; then base=$((base + 30))
    elif [ "$lowc" -ge 2 ] 2>/dev/null; then base=$((base + 20))
    fi
    [ "$hic" -ge 6 ] 2>/dev/null && base=$((base - 12))
  fi
  # CPU 争用(PSI): /proc/stat 的利用率会把"任务在排队等 CPU"平均掉,
  # 利用率没到顶但任务在等(突发/多任务争用)时, PSI 才看得出真实需求。
  # 必须叠加绝对需求下限(忙时或大核 >= 45): 轻载下几个后台线程在小核排队
  # 就能把 some avg10 顶到两位数, 单用 PSI 会把频率白白抬起来(Kin-Daemon 实测结论)。
  # 权重 +12(不是 +20): 实机 trace 显示轻载基线分 19, +20 正好顶到 39
  # = SM_EXIT_SAVE, 单因素就能把 powersave 翻回 balanced, 又随 PSI 回落翻回去,
  # 造成每 ~20s 一次换档抖动。+12 时 19 -> 31 不跨阈值; 真实负载靠
  # busy>=55(+10) / 大核(+4~18) / 低帧(+30) 叠加才升档, 与 PSI 分工不冲突。
  # 阈值 20 的实机复核(PLC110, 5s 采样 60 点): 空闲 some avg10 在 8~25
  # (多数 11~19), 压 3 路负载时 34~36。阈值 20 挡不住空闲噪声, 所以
  # >=45 的需求下限不能去掉 —— 两个条件同时成立才算"真在排队"。
  psi_used=0
  if [ "$psi" -ge 20 ] 2>/dev/null; then
    if [ "$busy" -ge 45 ] 2>/dev/null || [ "$SM_PRIME" -ge 45 ] 2>/dev/null; then
      base=$((base + 12))
      psi_used=1
    fi
  fi
  # 调度倾向偏置: 只加在这一步, 前面的硬规则(息屏/高温/应用策略/游戏)已各自返回
  if [ "$SM_TEND_BIAS" -ne 0 ] 2>/dev/null; then
    base=$((base + SM_TEND_BIAS))
  fi
  [ "$base" -lt 0 ] && base=0
  [ "$base" -gt 100 ] && base=100
  # 原始分先过 EMA 再进滞回映射(单轮噪声不再单独跨阈值)
  smart_score_ema "$base"
  score="$SM_SCORE"

  # 带滞回映射, 单次只跳一档
  want="$cur"
  case "$cur" in
    performance) [ "$score" -lt "$SM_EXIT_PERF" ] && want=balanced ;;
    balanced)
      if   [ "$score" -ge "$SM_ENTER_PERF" ]; then want=performance
      elif [ "$score" -le "$SM_ENTER_SAVE" ]; then want=powersave
      fi ;;
    powersave) [ "$score" -ge "$SM_EXIT_SAVE" ] && want=balanced ;;
    *) want=balanced ;;
  esac

  # 最小驻留(温度原因已在上面提前返回, 这里只管评分换档)
  if [ "$want" != "$cur" ] && [ "$since" -gt 0 ] && [ "$now" -gt 0 ]; then
    if [ $((now - since)) -lt "$SM_STAY" ]; then
      want="$cur"
    fi
  fi

  reason="均衡"
  [ "$want" = performance ] && reason="负载/帧率需要性能"
  [ "$want" = powersave ]   && reason="负载低, 省电优先"
  # 只在真的降档(或原地保持)时才叫"降档": 实机日志出现过
  # "智能档位 -> balanced (温度偏高, 降档)", 实际是从 powersave 升到 balanced,
  # 文案与动作相反, 用户看通知会误解。powersave -> balanced 不算降档。
  local temp_reason=1
  [ "$cur" = powersave ] && [ "$want" = balanced ] && temp_reason=0
  [ "$t" -ge 50000 ] 2>/dev/null && [ "$want" != performance ] \
    && [ "$temp_reason" = 1 ] && reason="温度偏高, 降档"
  [ "$fps" != "-1" ] && [ "$lowc" -ge 2 ] 2>/dev/null && [ "$want" = performance ] && reason="持续低帧, 升档"
  [ "$SM_PRIME" -ge 90 ] 2>/dev/null && [ "$want" = performance ] && reason="大核吃满, 升档"
  [ "$psi_used" = 1 ] 2>/dev/null && [ "$want" = performance ] && reason="CPU 争用(PSI), 升档"

  # 换档才更新驻留时刻, 才写遥测
  if [ "$want" != "$cur" ]; then
    smart_stats_add "$cur" $((now - since))
    smart_trace "$cur" "$want" "$reason" "$score"
    since="$now"
  fi
  echo "$lowc $hic $since" > "$SMART_CNT" 2>/dev/null
  smart_save "$cur" "$want" "$score" "$now" "$reason"
  printf '%s' "$want"
}

smart_status() {
  [ -f "$SMART_STATE" ] && cat "$SMART_STATE" 2>/dev/null
}

# source 守卫
[ "$(basename "$0" 2>/dev/null)" = "smart.sh" ] || return 0 2>/dev/null
case "$1" in
  decide) shift; smart_decide "$1" "$2" "$3" "$4" "$5" "$6" ;;
  status) smart_status ;;
  temp)   met_temp; printf '%s\n' "$MET_TEMP" ;;
  busy)   met_cpu; printf '%s\n' "$MET_BUSY" ;;
  fps)    met_fps; printf '%s\n' "$MET_FPS" ;;
  trace)  [ -f "$SMART_TRACE" ] && tail -n "${2:-10}" "$SMART_TRACE" ;;
  stats)  [ -f "$SMART_STATS" ] && cat "$SMART_STATS" ;;
esac
