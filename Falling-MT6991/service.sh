#!/system/bin/sh
# ============================================================
# Falling-MT6991 service.sh (v3.0 总入口, 无 CLI, 全部走库函数)
# 启动顺序: 解锁 cpufreq -> 回滚保护 -> 基础档位编排(balanced)
#          -> 温控状态 -> 守护进程(智能决策)
# 开机先套 balanced(最稳), 守护进程 5s 内按温度/负载/帧率自动接管
# ============================================================
MODDIR=${0%/*}
# shellcheck disable=SC1091
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"
[ -f "$MODDIR/lib/governor.sh" ] && . "$MODDIR/lib/governor.sh"
[ -f "$MODDIR/lib/apply.sh" ] && . "$MODDIR/lib/apply.sh"

# 早期解锁 cpufreq 节点
unlock_cpufreq

# 等待 boot 完成
while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ]; do sleep 2; done

# ---- 迁移旧版应用配置(一次性, v4.0 统一到 apps.conf) ----
# 旧格式: app_profiles.conf / app_policy.conf (包名=档位) + app_touch.conf (包名=码)
# 新格式: apps.conf (SCREEN_OFF_PROFILE= | 包名=档位 | 包名@touch=码)
APPS="$MODDIR/config/apps.conf"
[ -f "$APPS" ] || { echo "SCREEN_OFF_PROFILE=powersave" > "$APPS"; echo "# 包名=档位 (performance|balanced|powersave|powersave+)" >> "$APPS"; }

migrate_rules() { # $1=旧文件 $2=目标文件 $3=转换器(可选)
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      \#*|"") continue ;;
      *) ;;
    esac
    case "$line" in
      SCREEN_OFF_PROFILE=*) ;; # 保留新文件已有
      *)
        if [ -n "$3" ]; then line=$($3 "$line"); fi
        grep -qxF "$line" "$dst" 2>/dev/null || echo "$line" >> "$dst"
        ;;
    esac
  done < "$src"
  log_info "旧配置已迁移: $src -> $(basename "$dst")"
  mv "$src" "$src.migrated" 2>/dev/null
}

# 旧专属采样率格式(包名=码) -> 新格式(包名@touch=码)
conv_touch() { echo "${1%=*}@touch=${1#*=}"; }

if [ -f "$MODDIR/config/app_profiles.conf" ]; then
  migrate_rules "$MODDIR/config/app_profiles.conf" "$APPS" ""
fi
if [ -f "$MODDIR/config/app_policy.conf" ]; then
  migrate_rules "$MODDIR/config/app_policy.conf" "$APPS" ""
fi
if [ -f "$MODDIR/config/app_touch.conf" ]; then
  migrate_rules "$MODDIR/config/app_touch.conf" "$APPS" conv_touch
fi

# ---- 开机基础编排(balanced; 智能守护 5s 内接管) ----
# bootloop 保护: 连续两次开机都失败才回退到最保守的省电档
rollback_mark_boot smart
if rollback_should_revert; then
  log_err "service: boot-loop guard -> powersave"
  sys_apply powersave
else
  # 应用成功才 ack(清 bootloop 计数), 失败不 ack(留给下次开机继续判)
  if sys_apply balanced; then
    rollback_ack
  else
    log_err "service: 基础编排失败, 不回滚计数"
  fi
fi

# ---- 守护进程(全智能: 档位/触控/息屏) + 存活监控 ----
# 旧版直接 & 起一个就完事: 被 LMK 杀掉或自己崩了, 模块就静默失效,
# 用户只看到"调度不生效"而没有任何提示。这里用父循环兜住:
#   rc=0        -> 有人显式停用(TERM), 不再拉起
#   rc!=0       -> 5s / 10s / 15s / 20s 退避重启
#   单次存活 >=120s 视为稳定, 失败计数清零(否则几个偶发崩溃累计到 5 就永久停摆)
#   连续 5 次失败 -> 放弃并记错误日志(此时一定是配置坏了, 硬拉只会刷日志)
if [ "$(sys_opt daemon)" = "1" ]; then
  DAEMON=""
  if [ -f "$MODDIR/bin/falling_daemon" ]; then
    DAEMON="$MODDIR/bin/falling_daemon"
  elif [ -f "$MODDIR/system/bin/falling_daemon" ]; then
    DAEMON="$MODDIR/system/bin/falling_daemon"
  fi
  if [ -n "$DAEMON" ]; then
    runtime_dir
    (
      d_fails=0
      while :; do
        d_t0=$(date +%s)
        "$DAEMON"
        d_rc=$?
        [ "$d_rc" = 0 ] && break
        d_t1=$(date +%s)
        [ $((d_t1 - d_t0)) -ge 120 ] && d_fails=0
        d_fails=$((d_fails + 1))
        printf '%s\n' "$d_fails" > "$PMK_RUNTIME_DIR/daemon.restarts" 2>/dev/null
        if [ "$d_fails" -ge 5 ]; then
          log_err "service: 守护连续异常退出 $d_fails 次(最后 rc=$d_rc), 停止拉起, 请检查 apps.conf/system.conf"
          break
        fi
        log_warn "service: 守护异常退出 rc=$d_rc, $((d_fails * 5))s 后重启"
        sleep $((d_fails * 5))
      done
    ) &
  else
    log_err "service: 找不到 falling_daemon, 后台调度不会启动"
  fi
fi

log_info "service: boot optimization done"
