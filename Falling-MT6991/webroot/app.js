/* ============================================================
   Falling-MT6991 调度中心 WebUI
   骨架: 底部 4 Tab(状态/调度/触控/我的) + 分组卡片钻取子页
   外观: data-theme="light" | "dark"(浅色/深色)
   KernelSU 协议: window.ksu.exec(cmd, '{}', cb)
   ============================================================ */
const MOD = "/data/adb/modules/falling-mt6991";
const CFG = MOD + "/config";
const LOGF = "/data/local/tmp/falling_mt6991.log";

let exec = null, toast = null;
const $ = id => document.getElementById(id);

const ZH_PROFILE = { performance: "性能", balanced: "均衡", powersave: "省电", "powersave+": "极限省电", game_medium: "中度游戏" };
const ZH_SCHED = { game: "游戏/低延迟", balance: "均衡", powersave: "省电" };
const ZH_GOV = { performance: "性能", powersave: "省电", sugov_ext: "系统调度", schedutil: "调度器", scx: "风驰", conservative: "保守", dummy: "默认" };
const ZH_LAYER = {
  smart: "智能调度",
  screen_off: "息屏省电",
  oem_game: "官方风驰",
  app_policy: "应用策略",
  default: "默认档位"
};

function initKsu() {
  // 优先走 host.js 的归一化 exec(KernelSU / Magisk / APatch 同一套调用);
  // host.js 没加载上(老缓存)时退回原来的 window.ksu.exec 直调。
  const hostExec = window.FallingHost && window.FallingHost.exec;
  if (typeof hostExec === "function") {
    exec = hostExec;
    toast = msg => { try { window.ksu && window.ksu.toast && window.ksu.toast(msg); } catch (e) {} };
  } else if (typeof window.ksu !== "undefined") {
    exec = cmd => new Promise((resolve, reject) => {
      const cb = `cb_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
      window[cb] = (errno, stdout, stderr) => {
        resolve({ errno, stdout: stdout || "", stderr: stderr || "" });
        delete window[cb];
      };
      try { window.ksu.exec(cmd, "{}", cb); } catch (e) { reject(e); delete window[cb]; }
    });
    toast = msg => { try { window.ksu.toast && window.ksu.toast(msg); } catch (e) {} };
  } else {
    // 预览模式: 返回模拟数据, 让仪表台有内容可看
    const SIM_OVERVIEW =
      "load=0.42 0.38 0.35\n" +
      "arch=AArch64 Processor rev 14 cores=8\n" +
      "t:cpu-thermal 52300\nt:soc-thermal 48500\nt:gpu-thermal 46100\n" +
      "c:policy0 0 1 2 3 900000 339000 2400000 sugov_ext\n" +
      "c:policy4 4 5 6 3000000 700000 3000000 performance\n" +
      "c:policy7 7 1800000 798000 1800000 performance\n" +
      "g:gov=dummy cur=988000000 max=1508000000 load=42 boost=1 dvfs=1\n" +
      "batt=39000\ncyc=86\nfpslow=98\n" +
      "fpsraw=Renderer  current  target|r1 60 60 58 60|r2 60 60 30 60";
    const SIM_DEVICE =
      "MODEL=OnePlus (模拟预览)\nSOC=mt6991\n";
    const SIM_FPS =
      "Renderer   current  target\nr1 60 60 58 60\nr2 60 60 30 60";
    exec = async cmd => {
      const c = String(cmd);
      if (c.includes("=prof=")) return { errno: 0, stdout:
        "=prof=balanced\n=ts=daily\n" +
        "=ctrl=layer=daily|profile=balanced|pkg=|screen=on|fps_boost=0|scene=daily\n" +
        "=scn=daily\n=dev=MODEL=OnePlus (模拟预览)|SOC=mt6991\n=rtp=balanced\n" +
        "=sched=profile=game|drift=0|bad=0|pelt=4|uclamp_ctrl=1|touch_boost=1/70|cfs_energy_aware=1|boost_ta=1|hmbird_isolate=1|hmbird_parctrl=55/40|hmbird_misfit=1024|hmbird_slim=1|isoctrl=65/50|scx_gov_ctrl=1|slim_walt=1|rt_runtime=950000|uclamp_max=1024\n" +
        "=dly=PROFILE=balanced|SCHED=balance|TOUCH=daily|FPS_EN=1|IO=daily\n" +
        "=gme=PROFILE=performance|SCHED=game|TOUCH=game|FPS_EN=1|IO=game\n" +
        "=pwr=PROFILE=powersave|SCHED=powersave|TOUCH=daily|FPS_EN=0|IO=daily\n" +
        "=soff=PROFILE=powersave+|SCHED=powersave|TOUCH=daily|FPS_EN=0|IO=daily\n" +
        "=fps=ENABLE=1|LOW_PCT=70|RECOVER_PCT=90", stderr: "" };
      if (c.includes('echo "load=') && c.includes("cut -d")) return { errno: 0, stdout: SIM_OVERVIEW, stderr: "" };
      if (c.includes("device.conf")) return { errno: 0, stdout: SIM_DEVICE, stderr: "" };
      if (c.includes("awk") && c.includes("fpsgo_status")) return { errno: 0, stdout: "98", stderr: "" };
      if (c.includes("fpsgo_status")) return { errno: 0, stdout: SIM_FPS, stderr: "" };
      if (c.includes("falling_mt6991.log")) return { errno: 0, stdout: "[info] 预览模式日志模拟\n[info] profile applied: balanced\n", stderr: "" };
      if (c.includes("changelog.md")) return { errno: 0, stdout: "Falling-MT6991 更新日志\nv9.0.0 (2026-09-24)\n  - 移除游戏调度, 游戏 CPU 交官方接管\n", stderr: "" };
      if (c.includes("usergov.sh status")) return { errno: 0, stdout: "probe=ok\nactive=no\npid=", stderr: "" };
      if (c.includes("system.conf")) return { errno: 0, stdout: "daemon=1\ntouch=1\ngame_mode=official\ntendency=save\nnotify=1\ndebug=0\nzram=0\ntheme=light\n", stderr: "" };
      if (c.includes("scene.conf")) return { errno: 0, stdout: "daily", stderr: "" };
      if (c.includes("/scenes/")) return { errno: 0, stdout: "PROFILE=balanced\nSCHED=balance\nTOUCH=daily\nFPS_EN=1", stderr: "" };
      if (c.includes("scheme.sh") && c.includes("echo yes")) return { errno: 0, stdout: "yes", stderr: "" };
      if (c.includes("/schemes/")) return { errno: 0, stdout: "NAME=均衡向\nDESC=日常均衡 · 游戏性能 · 省电节能 · 息屏极限省电。\n\n[daily]\nPROFILE=balanced\n", stderr: "" };
      if (c.includes("scheme.current")) return { errno: 0, stdout: "balance", stderr: "" };
      if (c.includes("sched.state")) return { errno: 0, stdout: "profile=game\npelt=4\nuclamp_ctrl=1\ntouch_boost=1/70\ncfs_energy_aware=1\nboost_ta=1\nhmbird_isolate=1\nhmbird_parctrl=55/40\nhmbird_misfit=1024\nhmbird_slim=1\nisoctrl=65/50\nscx_gov_ctrl=1\nslim_walt=1", stderr: "" };
      if (c.includes("pgrep -f falling_daemon")) return { errno: 0, stdout: "1234", stderr: "" };
      if (c.includes("thermal/thermal_zone")) return { errno: 0, stdout: "cpu 52300\ngpu 46100", stderr: "" };
      if (c.includes("power_supply/battery/temp")) return { errno: 0, stdout: "39000", stderr: "" };
      if (c.includes("cycle_count")) return { errno: 0, stdout: "86", stderr: "" };
      if (c.includes("uname -r")) return { errno: 0, stdout: "6.6.30-android15", stderr: "" };
      if (c.includes("module.prop")) return { errno: 0, stdout: "v1.1.0", stderr: "" };
      if (c.includes("getprop ro.build.fingerprint")) return { errno: 0, stdout: "OnePlus/PLC110/PLC110:15/A.13/1234:user/release-keys", stderr: "" };
      if (c.includes("getenforce")) return { errno: 0, stdout: "Enforcing", stderr: "" };
      if (c.includes("pm list packages -3")) return { errno: 0, stdout: "package:com.tencent.tmgp.sgame\npackage:com.miHoYo.Yuanshen\npackage:com.hypergryph.arknights\npackage:com.netease.mc\n", stderr: "" };
      if (c.includes("pm list packages -s")) return { errno: 0, stdout: "package:com.android.settings\npackage:com.android.systemui\n", stderr: "" };
      if (c.includes("apps.conf")) return { errno: 0, stdout: "SCREEN_OFF_PROFILE=powersave\ncom.miHoYo.Yuanshen=performance\ncom.tencent.tmgp.sgame@touch=360\ncom.hypergryph.arknights=game_medium\n", stderr: "" };
      if (c.includes("oplus_mm_config.xml")) return { errno: 0, stdout:
        "<?xml version=\"1.0\"?>\n<config>\n    <prjname>24813</prjname>\n    <memory_24g>\n        <zram0>\n            <disk_size_mb>10240</disk_size_mb>\n            <increase_limit>0</increase_limit>\n            <comp_algorithm>lz4</comp_algorithm>\n            <limit_size>0</limit_size>\n        </zram0>\n        <zram_opt>\n            <vm_swappiness>160</vm_swappiness>\n            <direct_swappiness>60</direct_swappiness>\n        </zram_opt>\n    </memory_24g>\n    <memory_16g>\n        <zram0>\n            <disk_size_mb>16384</disk_size_mb>\n            <increase_limit>0</increase_limit>\n            <comp_algorithm>lz4</comp_algorithm>\n            <limit_size>0</limit_size>\n        </zram0>\n        <zram_opt>\n            <vm_swappiness>160</vm_swappiness>\n            <direct_swappiness>160</direct_swappiness>\n        </zram_opt>\n    </memory_16g>\n    <memory_12g>\n        <zram0>\n            <disk_size_mb>12288</disk_size_mb>\n            <increase_limit>0</increase_limit>\n            <comp_algorithm>zstd</comp_algorithm>\n            <limit_size>0</limit_size>\n        </zram0>\n        <zram_opt>\n            <vm_swappiness>160</vm_swappiness>\n            <direct_swappiness>160</direct_swappiness>\n        </zram_opt>\n    </memory_12g>\n</config>", stderr: "" };
      if (c.includes('echo "size=')) return { errno: 0, stdout: "size=12884901888\nalg=lz4 [lz4] [lz4hc] [lzo] [lzo-rle] [zstd]\nswap=vm_swappiness : 160\ndirect_swappiness : 160\nmem=16406056", stderr: "" };
      if (c.includes("grep MemTotal")) return { errno: 0, stdout: "16406056", stderr: "" };
      if (c.includes("触控.md")) return { errno: 0, stdout: "日常=touchHidlTest -c wo 0 182 1\n游戏=touchHidlTest -c wo 0 182 360\n游戏包名=com.tencent.tmgp.sgame\n", stderr: "" };
      return { errno: -1, stdout: "", stderr: "simulation" };
    };
    toast = msg => showToast(msg);
    showToast("预览模式: 模拟数据, 未检测到 KernelSU");
  }
}

function showToast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(t._h);
  t._h = setTimeout(() => (t.hidden = true), 2200);
}
const msg = m => { showToast(m); toast && toast(m); };
const vib = ms => { try { navigator.vibrate && navigator.vibrate(ms); } catch (e) {} };

let cfYes = null;
function confirmDanger(title, text, fn) {
  $("cf-title").textContent = title;
  $("cf-msg").textContent = text;
  cfYes = fn;
  $("confirm-modal").hidden = false;
  vib(12);
}
function closeConfirm() { $("confirm-modal").hidden = true; cfYes = null; }

const readFile = async p => (await exec(`cat "${p}" 2>/dev/null`)).stdout;
const writeFile = async (p, c) =>
  (await exec(`printf '%s' '${c.replace(/'/g, "'\"'\"'")}' > "${p}"`)).errno === 0;
const sh = async s => (await exec(s)).stdout.trim();

/* system.conf 缓存
   ----------
   为什么需要缓存: 在 KernelSU 里每次 exec 都要起一个 root shell,
   实测一次 150~400ms。旧代码里 sysOpt() 每次都 cat 一遍文件,
   而设置页切一次要读 5 个开关 + 主题 + ZRAM 开关 = 6~7 次 exec,
   光等 exec 就要 1~2 秒 —— 这就是「设置页面非常卡」的主因。
   现在: 一次读进内存, 解析全部键; 写入后主动失效。
   ------------------------------------------------------------ */
let CONF_CACHE = null;
async function readConf() {
  if (CONF_CACHE === null) CONF_CACHE = await readFile(CFG + "/system.conf");
  return CONF_CACHE;
}
function invalidateConf() { CONF_CACHE = null; }
// 读 system.conf 键值(兼容数字与字符串值, 如 theme=light)
const sysOpt = async k => {
  const c = await readConf();
  const m = new RegExp("^" + k + "=(.*)$", "m").exec(c);
  return m ? m[1].trim() : "";
};
// 一次读出多个键, 只花一次 exec
async function sysOpts(keys) {
  const c = await readConf();
  const out = {};
  for (const k of keys) {
    const m = new RegExp("^" + k + "=(.*)$", "m").exec(c);
    out[k] = m ? m[1].trim() : "";
  }
  return out;
}
// 写 system.conf: 已存在则替换, 不存在则追加(修复新增键 sed 无匹配不写入导致外观开关失效)
const setOpt = async (k, v) => {
  invalidateConf();
  return exec(`sed -i 's/^${k}=.*/${k}=${v}/' "${CFG}/system.conf"; grep -q '^${k}=' "${CFG}/system.conf" || printf '%s\\n' '${k}=${v}' >> "${CFG}/system.conf"`);
};

const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const SAFE_PKG = /^[A-Za-z0-9._]+$/;
const delRule = async (file, pkg) => {
  await exec(`awk -v p="${pkg}" 'index($0, p "=") == 1 { next } { print }' "${file}" > "${file}.t" && mv "${file}.t" "${file}"`);
};
const delTouchRule = async (file, pkg) => {
  await exec(`awk -v p="${pkg}" 'index($0, p "@touch=") == 1 { next } { print }' "${file}" > "${file}.t" && mv "${file}.t" "${file}"`);
};
const cat = async f => (await exec(`cat "${f}" 2>/dev/null`)).stdout.trim();

function controlText(kv) {
  const layer = ZH_LAYER[kv.layer] || kv.layer || "默认档位";
  const prof = !kv.profile || kv.profile === "-" ? "" : (ZH_PROFILE[kv.profile] || kv.profile);
  const extra = [];
  if (kv.pkg) extra.push(kv.pkg);
  if (prof) extra.unshift(prof);
  return extra.length ? `${layer} · ${extra.join(" · ")}` : `${layer}`;
}

/* v3.4.0 极致省电: 展示限制层的最终生效态。
   runtime/extreme.state 由守护进程发布, 已经包含游戏豁免 ——
   所以这里显示的是"实际生效", 不是"用户开关"。
   extRaw: "extreme=1" / "extreme=0" / ""(守护进程还没发布) */
function renderExtremeState(extRaw, ctrl) {
  const el = $("extreme-state");
  if (!el) return;
  const on = /(^|\|)extreme=1(\||$)/.test(extRaw || "");
  const known = /extreme=/.test(extRaw || "");
  if (!known) {
    el.innerHTML = '<span class="muted">守护进程尚未发布状态</span>';
    return;
  }
  const inGame = ctrl && (ctrl.layer === "oem_game");
  let txt, hint;
  if (on) {
    txt = "生效中";
    hint = "频率与 GPU 上限已压低，升频节奏已锁住";
  } else if (inGame) {
    txt = "游戏期间自动失效";
    hint = "游戏不做极致省电";
  } else {
    txt = "未生效";
    hint = "已关闭";
  }
  el.innerHTML = row("当前状态", txt) + row("说明", hint);
}

/* 单独刷新极致省电状态(开关切换后调用)。
   不新增 exec 批次: 复用 loadStatus 已经读到的 control 与 extreme.state,
   这里只把 runtime/extreme.state 再读一次(文件很小, 一次 exec)。 */
async function loadExtremeState() {
  const ext = await sh(`cat ${CFG}/runtime/extreme.state 2>/dev/null`);
  const ctrl = await sh(`cat ${CFG}/runtime/control 2>/dev/null | tr '\\n' '|'`);
  const kv = {};
  String(ctrl || "").split("|").forEach(l => {
    const i = l.indexOf("=");
    if (i > 0) { const K = l.slice(0, i).trim(), V = l.slice(i + 1).trim(); if (K) kv[K] = V; }
  });
  renderExtremeState(ext, kv);
}

/* 设备常量: 只读一次(版本/SELinux/物理内存/核心数), 不再每轮 exec */
let DEV = null;
let evTick = 0;
async function loadDeviceConst() {
  if (DEV) return DEV;
  const out = await sh(`echo "ver=$(grep '^version=' "${MOD}/module.prop" 2>/dev/null | cut -d= -f2)";
echo "se=$(getenforce 2>/dev/null)";
echo "mem=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)";
echo "cores=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)"`);
  const g = k => { const m = new RegExp("^" + k + "=(.*)$", "m").exec(out); return m ? m[1].trim() : ""; };
  DEV = { ver: g("ver") || "--", se: g("se") || "--", memKB: +g("mem") || 0, cores: g("cores") || "--" };
  return DEV;
}

// 闭环状态缓存: loop.state 变化慢(每轮才可能换档), 不必每 2s 重新 exec。
// loadStatus 是 5s 一轮, 这里单独 15s 拉一次就够。
let loopCache = {};
let loopTickAt = 0;

async function loadStatus() {
  // 闭环状态: 15s 拉一次(它只在换档时变)
  const nowS = Date.now();
  if (nowS - loopTickAt > 15000) {
    loopTickAt = nowS;
    try { loopCache = (await loadLoopState()).loop; } catch (e) {}
  }
  const s = await sh(`echo "=ts=$(cat ${CFG}/runtime/touch.state 2>/dev/null)";
echo "=ctrl=$(cat ${CFG}/runtime/control 2>/dev/null | tr '\\n' '|')";
echo "=dev=$(cat ${CFG}/device.conf 2>/dev/null | tr '\\n' '|')";
echo "=smart=$(cat ${CFG}/runtime/smart.state 2>/dev/null | tr '\\n' '|')";
echo "=ext=$(cat ${CFG}/runtime/extreme.state 2>/dev/null | tr '\\n' '|')";
echo "=sched=$(cat ${CFG}/runtime/sched.state 2>/dev/null | tr '\\n' '|')"`);
  const b = k => { const m = new RegExp("^=" + k + "=(.*)$", "m").exec(s); return m ? m[1] : ""; };
  const kv = k => { const o = {}; String(b(k)).split("|").forEach(l => { const i = l.indexOf("="); if (i > 0) { const K = l.slice(0, i).trim(), V = l.slice(i + 1).trim(); if (K) o[K] = V; } }); return o; };

  const sm = kv("smart");
  const prof = sm.profile || "balanced";
  const ts = b("ts") || "daily";
  const ctrl = kv("ctrl");


  const sk = kv("sched");
  // 温控不再有开关: 顶栏直接显示当前降频比例(来自 sched.state 的 thermal_ratio)
  const tr = sk.thermal_ratio ? +sk.thermal_ratio : 100;

  /* v3.1.0 原创: 闭环仪表 + 分簇热力
     loop.state 与 smart.state 在同一批数据里, 不额外 exec(每轮多一次 exec 会拖慢 UI) */
  renderClusterHeat(sm);
  renderLoop({ sm: sm, ratio: tr, loop: loopCache });
  /* 硬件速览(概览页) */
  if ($("hw-overview")) {
    $("hw-overview").innerHTML =
      row("守护状态", (($("daemon-state") || {}).textContent) || "--") +
      row("当前档位", (ZH_PROFILE[sm.profile] || sm.profile || "-") + "档") +
      row("调度层", sk.pelt ? "PELT " + sk.pelt + "x" : "正常") +
      row("温控降额", tr >= 100 ? "全速 (100%)" : tr + "%") +
      row("触控", ts.indexOf("code:") === 0 ? "专属档" : ts === "game" ? "游戏档" : "日常档") +
      row("核心数", sm.cores || "--");
  }
  const any = sk.pelt || sk.uclamp_ctrl || sk.touch_boost || sk.cfs_energy_aware || sk.boost_ta ||
              sk.hmbird_isolate || sk.hmbird_parctrl || sk.hmbird_misfit || sk.hmbird_slim ||
              sk.isoctrl || sk.scx_gov_ctrl || sk.slim_walt;
  if (any) {
    $("sched-info").innerHTML =
      row("PELT 响应", (sk.pelt || "-") + "x") +
      row("MTK uclamp", sk.uclamp_ctrl === "1" ? "开" : "关") +
      row("触控 boost", sk.touch_boost || "-") +
      row("EAS", sk.cfs_energy_aware === "1" ? "开" : (sk.cfs_energy_aware ? "关" : "-")) +
      row("top-app boost", sk.boost_ta === "1" ? "开" : (sk.boost_ta ? "关" : "-")) +
      row("大核隔离", sk.hmbird_isolate === "1" ? "开" : (sk.hmbird_isolate ? "关" : "-")) +
      row("并行控制", sk.hmbird_parctrl || "-") +
      row("isolate 控制", sk.isoctrl || "-") +
      row("misfit 阈值", sk.hmbird_misfit || "-") +
      row("轻载省电", sk.hmbird_slim === "1" ? "开" : (sk.hmbird_slim ? "关" : "-")) +
      row("scx 参与", sk.scx_gov_ctrl === "1" ? "开" : (sk.scx_gov_ctrl ? "关" : "-")) +
      row("slim 追踪", sk.slim_walt === "1" ? "开" : (sk.slim_walt ? "关" : "-")) +
      row("漂移 / 拒写", `${sk.drift || 0} 项 / ${sk.bad || 0} 项`);
  } else {
    const raw = await exec(`sh ${MOD}/lib/sched.sh status 2>&1`);
    $("sched-info").innerHTML =
      row("调度层", "读取失败(无输出)") +
      row("errno", String(raw.errno)) +
      row("stdout", ((raw.stdout || "").trim().slice(0, 60) || "(空)")) +
      row("stderr", ((raw.stderr || "").trim().slice(0, 60) || "(空)"));
  }

  // device.conf 多行被 tr '\n' '|' 拼成一行: 取值必须截到 '|' 为止,
  // 否则 ^MODEL=(.*)$ 会把整份 device.conf 都当成型号
  const g = k => { const m = new RegExp("(?:^|\\|)" + k + "=([^|]*)").exec(b("dev")); return m ? m[1] : "-"; };
  $("control-val").textContent = controlText(ctrl);
  /* 极致省电限制层状态: runtime/extreme.state 是守护进程发布的最终态
     (已含游戏豁免), 与上面的数据同一批 exec 读出, 不额外发请求 */
  renderExtremeState(b("ext"), ctrl);
  // 守护条副行: 设备 + 默认档
  const gs = $("guard-sub");
  if (gs) gs.textContent = `${g("MODEL")} · 默认 ${ZH_PROFILE[prof] || prof}`;
  // 磁贴: 智能调度/工具
  $("mt-scheme-name").textContent = (ZH_PROFILE[prof] || prof) + "档";
  if ($("mt-smart")) $("mt-smart").textContent = sm.reason || "自动";
  // 智能调度页: 当前决策明细(复用主状态这一批数据, 不额外 exec)
  if ($("smart-info")) {
    const sTemp = +sm.temp || 0, sLoad = +sm.load || 0, sFps = sm.fps || "-1";
    const sBusy = sm.busy === undefined ? -1 : +sm.busy;
    const sScore = sm.score && sm.score !== "0" ? sm.score + " / 100" : "—";
    $("smart-info").innerHTML =
      row("当前档位", ZH_PROFILE[sm.profile] || sm.profile || "-") +
      row("决策原因", sm.reason || "-") +
      row("综合评分", sScore) +
      row("CPU 温度", sTemp > 0 ? (sTemp / 1000).toFixed(0) + "°C" : "--") +
      row("温控上限", !sk.thermal_ratio || sk.thermal_ratio === "100" ? "全速 (100%)" : sk.thermal_ratio + "%") +
      row("CPU 占用率 (5s)", sBusy >= 0 ? sBusy + "%" : "--") +
      row("分簇占用", clusterText(sm)) +
      row("大核占用", primeText(sm)) +
      row("最低帧率达标率", sFps !== "-1" ? sFps + "%" : "--") +
      row("核心数", sm.cores || "--") +
      row("调度倾向", TEND_NAME[sm.tendency] || "均衡") +
      row("评分说明", sBusy >= 0 ? "温度越高扣分越多；占用率 ≥85% 或低帧加分" : "温度越高扣分越多；负载与低帧加分；升档要越过更高阈值");
  }
  $("mt-scheme-th").textContent = sk.pelt ? "PELT " + sk.pelt + "x" : "正常";
  $("mt-tools-model").textContent = g("MODEL") !== "-" ? g("MODEL") : "--";


  // 帧率原始表只在 GPU 子页开着时才取: 整份 fpsgo_status 文本不小, 每轮传会拖慢 UI
  const wantRaw = 'echo "fpsraw=";';
  const statOut = await sh(`echo "load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)";
echo "arch=$(grep -m1 '^Processor' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//') cores=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)";
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat $z/type 2>/dev/null); [ -n "$t" ] || continue
  case "$t" in cpu-*|soc-*|gpu*|apu*) echo "t:$t $(cat $z/temp 2>/dev/null)";; esac
done;
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  echo "c:$(basename $p) $(cat $p/related_cpus 2>/dev/null) $(cat $p/scaling_cur_freq 2>/dev/null) $(cat $p/scaling_min_freq 2>/dev/null) $(cat $p/scaling_max_freq 2>/dev/null) $(cat $p/scaling_governor 2>/dev/null)"
done;
for d in /sys/class/devfreq/*mali*; do
  [ -d "$d" ] || continue
  echo "g:gov=$(cat $d/governor 2>/dev/null) cur=$(cat $d/cur_freq 2>/dev/null) max=$(cat $d/max_freq 2>/dev/null) load=$(cat /sys/module/ged/parameters/gpu_loading 2>/dev/null) boost=$(cat /sys/module/ged/parameters/boost_gpu_enable 2>/dev/null) dvfs=$(cat /sys/module/ged/parameters/gpu_dvfs_enable 2>/dev/null)"
  break
done;
echo "batt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)";
echo "cyc=$(cat /sys/class/power_supply/battery/cycle_count 2>/dev/null)";
echo "fpslow=$(awk 'NR>1 && \$5>=30 && \$4>0 { r=\$4/\$5; if (low=="" || r<low) low=r } END { if (low=="") print "-1"; else printf "%.0f", low*100 }' /sys/kernel/fpsgo/fstb/fpsgo_status 2>/dev/null)";
${wantRaw}`);
  const statLines = statOut.split("\n");

  const la = statLines.find(l => l.startsWith("load="));
  const laM = /load=([\d.]+ [\d.]+ [\d.]+)/.exec(la || "");
  $("loadavg").textContent = laM ? `1/5/15: ${laM[1]}` : "--";

  let cpuT = -1, gpuT = -1;
  statLines.forEach(l => {
    if (!l.startsWith("t:")) return;
    const a = l.slice(2).split(/\s+/);
    if (a.length < 2) return;
    const v = +a[1];
    if (!(v > 0)) return;
    if (/^cpu|^soc/.test(a[0])) cpuT = Math.max(cpuT, v);
    if (/^gpu/.test(a[0])) gpuT = Math.max(gpuT, v);
  });
  const heroTemp = $("hero-temp");
  if (cpuT > 0) {
    const c = cpuT / 1000;
    heroTemp.textContent = c.toFixed(0) + "°";
    heroTemp.className = "guard-temp " + tempCls(c);
  } else { heroTemp.textContent = "--°"; heroTemp.className = "guard-temp"; }

  const arM = /arch=([^\n]*?) cores=(\d+)/.exec(statLines.find(l => l.startsWith("arch=")) || "");
  const cpuTmp = $("cpu-temp");
  if (cpuT > 0) {
    const c = cpuT / 1000;
    cpuTmp.textContent = c.toFixed(0) + "°";
    cpuTmp.className = tempCls(c);
  } else { cpuTmp.textContent = "--"; cpuTmp.className = ""; }
  let archStr = arM ? arM[1].trim() : "";
  archStr = archStr.replace(/ \(.*\)$/, "");
  $("cpu-arch").textContent = (archStr ? archStr + " · " : "") + (arM ? arM[2] : "?") + " 核";
  $("cpu-model").textContent = g("MODEL") !== "-" ? g("MODEL") : "--";

  const battM = /^batt=(\d+)/m.exec(statOut);
  const cycM = /^cyc=(\d+)/m.exec(statOut);
  fillTemps(cpuT, gpuT, battM ? +battM[1] : -1, cycM ? cycM[1] : "--");

  // CPU 仪表 + 磁贴
  const cd = $("cpu-dash");
  cd.innerHTML = "";
  let cpuCur = 0, cpuMax = 0;
  statLines.forEach(l => {
    if (!l.startsWith("c:")) return;
    const m = /^c:policy(\d+)\s+([\d\s]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)/.exec(l);
    if (!m) return;
    const cpus = m[2].trim(), cur = +m[3], min = +m[4], max = +m[5], gov = m[6];
    const pct = max > 0 ? Math.min(100, Math.round((cur / max) * 100)) : 0;
    if (cur > cpuCur) { cpuCur = cur; cpuMax = max; }
    cd.insertAdjacentHTML("beforeend",
      `<div class="cpu-cell">
        <div class="cname">${cpus}</div>
        <div class="cgov">${ZH_GOV[gov] || gov}</div>
        <div class="cpu-bar"><span class="track"></span><i style="height:${pct}%"></i></div>
        <div class="cpct">${pct}%</div>
        <div class="cfreq">${(cur / 1e6).toFixed(2)}/${(max / 1e6).toFixed(2)}G</div>
      </div>`);
  });
  const la1 = laM ? parseFloat(laM[1].split(" ")[0]) : 0;
  $("mt-cpu-freq").textContent = cpuMax > 0 ? (cpuCur / 1e6).toFixed(2) + "G" : "--";
  /* 「整机占用」要的是百分比, 不是 loadavg 原始串。
     loadavg 是「可运行任务数」, 不是占用率; 放在这里既看不懂也误导。
     优先用 smart.state 里的 busy(5 秒窗口 CPU 占用率), 没有就退回 1 分钟 loadavg。 */
  const busyNow = sm.busy !== undefined && sm.busy !== "" && +sm.busy >= 0 ? +sm.busy : -1;
  $("mt-cpu-load").textContent = busyNow >= 0
    ? busyNow + "%"
    : (la1 > 0 ? Math.min(99, Math.round(la1 * 100)) + "%" : "--");

  // GPU 仪表 + 磁贴
  const gl = statLines.find(l => l.startsWith("g:"));
  const gm = gl ? /g:gov=(\S+) cur=(\S+) max=(\S+) load=(\S+) boost=(\S+) dvfs=(\S+)/.exec(gl) : null;
  const gd = $("gpu-dash");
  if (gm) {
    const load = +gm[4] > 0 ? Math.min(100, Math.round(+gm[4])) : 0;
    const C = (2 * Math.PI * 40).toFixed(1);
    const dash = ((load / 100) * +C).toFixed(1);
    const gpct = +gm[3] > 0 ? Math.round((+gm[2] / +gm[3]) * 100) : 0;
    const tRow = gpuT > 0
      ? `<div class="row2"><span>温度</span><b class="${tempCls(gpuT / 1000)}">${(gpuT / 1000).toFixed(0)}°</b></div>`
      : "";
    gd.innerHTML =
      `<div class="gpu-ring-wrap">
        <svg viewBox="0 0 100 100">
          <defs><linearGradient id="gpuGrad" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stop-color="#5aa9ff"/>
            <stop offset="100%" stop-color="#a78bfa"/>
          </linearGradient></defs>
          <circle class="gpu-ring-track" cx="50" cy="50" r="40"/>
          <circle class="gpu-ring-val" cx="50" cy="50" r="40" stroke-dasharray="${dash} ${C}"/>
        </svg>
        <div class="gpu-ring-center"><span class="gl">负载</span><span class="gv">${load}%</span><span class="gu">GPU</span></div>
      </div>
      <div class="gpu-side">
        <div class="row2"><span>调速器</span><b>${ZH_GOV[gm[1]] || gm[1]}</b></div>
        <div class="row2"><span>频率</span><b>${(gm[2] / 1e6).toFixed(2)} / ${(gm[3] / 1e6).toFixed(2)}G</b></div>
        <div class="row2"><span>频率占比</span><b>${gpct}%</b></div>
        <div class="row2"><span>GED Boost</span><b>${gm[5] === "1" ? "开" : "关"}</b></div>
        <div class="row2"><span>DVFS</span><b>${gm[6] === "1" ? "开" : "关"}</b></div>
        ${tRow}
      </div>`;
  } else {
    gd.innerHTML =
      `<div class="gpu-ring-wrap">
        <svg viewBox="0 0 100 100"><circle class="gpu-ring-track" cx="50" cy="50" r="40"/></svg>
        <div class="gpu-ring-center"><span class="gl">状态</span><span class="gv">--</span><span class="gu">GPU</span></div>
      </div>
      <div class="gpu-side"><div class="row2"><span>GPU</span><b>无 Mali</b></div></div>`;
  }

  const fpsOut = /^fpslow=(\S+)/m.exec(statOut)?.[1] || "-1";
  // 帧率达标率在闭环仪表里显示, 这里只留一份供其它地方读
  const fpsStr = fpsOut === "-1" ? "--" : fpsOut + "%";

  // 日志变化慢: 每 15s 刷一次, 且不阻塞主状态渲染
  if (evTick++ % 3 === 0) loadEvents();
  renderCounts();
}

async function loadEvents() {
  renderCounts();
  const el = $("event-log");
  if (!el) return;
  el.textContent = (await exec(`tail -n 12 "${LOGF}" 2>/dev/null`)).stdout || "(空)";
}

const tempCls = c => c < 45 ? "t-ok" : c < 60 ? "t-warm" : c < 75 ? "t-hot" : "t-burn";
const row = (k, v) => `<div class="kv-row"><span>${k}</span><b>${v}</b></div>`;

const RATES = [
  { c: "1",   label: "240Hz (1)" },
  { c: "12c", label: "360Hz · 一加11/12系 (12c)" },
  { c: "c",   label: "360Hz · 真我系 (c)" },
  { c: "360", label: "360Hz (360)" },
  { c: "258", label: "600Hz (258, 需支持)" },
  { c: "",    label: "自定义命令…" }
];

function rateSelect(sel, cur) {
  sel.innerHTML = RATES.map(r =>
    `<option value="${r.c}" ${r.c === cur ? "selected" : ""}>${r.label}</option>`).join("");
}

async function loadTouch() {
  const c = await readFile(CFG + "/触控.md");
  const g = k => { const m = new RegExp("^" + k + "=(.*)$", "m").exec(c); return m ? m[1] : ""; };
  const daily = g("日常"), game = g("游戏"), pkgs = g("游戏包名");
  const dCode = daily.split(" ").pop(), gCode = game.split(" ").pop();
  rateSelect($("touch-daily"), dCode);
  rateSelect($("touch-game"), gCode);
  $("touch-pkgs").value = pkgs;
  $("touch-preview").textContent = c || "(配置为空)";
  const np = pkgs.split(",").map(s => s.trim()).filter(Boolean).length;
}

async function saveTouch() {
  const dSel = $("touch-daily"), gSel = $("touch-game");
  const dCode = dSel.value, gCode = gSel.value;
  const custom = $("touch-custom").value.trim();
  const mk = (curCmd, code) => {
    if (code === "") return custom || curCmd;
    const parts = curCmd.trim().split(" ");
    if (parts.length < 2) return `${curCmd.trim()} ${code}`;
    parts[parts.length - 1] = code;
    return parts.join(" ");
  };
  const raw = await readFile(CFG + "/触控.md");
  const heads = raw.split("\n").map(l => l.trimEnd()).filter(l => /^\s*#/.test(l) && !l.includes("多包名")).join("\n").trim();
  const content =
    (heads ? heads + "\n" : "# Falling-MT6991 触控采样率配置 (WebUI 保存)\n") +
    `日常=${mk(raw.match(/^日常=(.*)$/m)?.[1] || "", dCode)}\n` +
    `游戏=${mk(raw.match(/^游戏=(.*)$/m)?.[1] || "", gCode)}\n` +
    `#多包名用英文逗号隔开\n` +
    `游戏包名=${$("touch-pkgs").value.trim()}\n`;
  const ok = await writeFile(CFG + "/触控.md", content);
  msg(ok ? "触控配置已保存 (5s 内生效)" : "保存失败");
  await loadTouch();
}
function syncCustomBox() {
  const show = $("touch-daily").value === "" || $("touch-game").value === "";
  $("touch-custom").style.display = show ? "block" : "none";
  $("touch-custom-wrap").style.display = show ? "block" : "none";
}

async function toggleNotifyValue(on) {
  await setOpt("notify", on ? 1 : 0);
  msg("通知设置已保存");
  return on;
}
async function testNotify() {
  const r = await exec(`sh ${MOD}/lib/notify.sh test`);
  msg(r.errno === 0 ? "测试通知已发送" : "发送失败");
}

// 写 system.conf 里的 0/1 开关
async function toggleFileValue(key, on) {
  await setOpt(key, on ? 1 : 0);
  msg("已保存");
  return on;
}

let POLICY_MAP = {};
let APP_USER = [], APP_SYS = [];
let APP_TAB = "user";
let POLICY_QUERY = "";

/* 应用展示信息
   ----------
   包名对普通用户不友好(尤其国产游戏的包名很长)。
   优先用宿主提供的元数据桥(和 NovaSched 一样),
   拿不到就退回包名末段, 至少让人认得出是哪个 App。
   ------------------------------------------------------------ */
const APP_LABELS = new Map();
const LABEL_QUERIED = new Set();
function pkgBase(pkg) {
  const s = String(pkg || "");
  const i = s.indexOf(":");
  return i > 0 ? s.slice(0, i) : s;
}
function appInfo(pkg) {
  const base = pkgBase(pkg);
  const label = APP_LABELS.get(base);
  const fallback = base.split(".").filter(Boolean).pop() || base || "未知应用";
  const name = label || fallback;
  return { pkg: base, name, initial: Array.from(name)[0] || "—" };
}
/* 头像底色: 由名字散列出色相, 同一个 App 永远同一个颜色 */
function avatarColor(name) {
  let hue = 7;
  for (const ch of String(name)) hue = (hue * 31 + ch.charCodeAt(0)) % 360;
  return `hsl(${hue}, 46%, 46%)`;
}
function loadAppLabels(packages) {
  const api = [window.ksu, window.magisk, window.apatch, window.KSU, window.mmrl]
    .find(x => x && typeof x.getPackagesInfo === "function");
  if (!api) return;
  const need = [...new Set(packages.map(pkgBase))]
    .filter(p => SAFE_PKG.test(p) && !LABEL_QUERIED.has(p));
  if (!need.length) return;
  for (let i = 0; i < need.length; i += 48) {
    const batch = need.slice(i, i + 48);
    try {
      const raw = api.getPackagesInfo(JSON.stringify(batch));
      const res = typeof raw === "string" ? JSON.parse(raw) : raw;
      if (Array.isArray(res)) {
        for (const info of res) {
          if (batch.includes(info.packageName) && typeof info.appLabel === "string" && info.appLabel.trim()) {
            APP_LABELS.set(info.packageName, info.appLabel.trim().slice(0, 120));
          }
        }
      }
    } catch (e) { /* 桥不可用就只用包名 */ }
    batch.forEach(p => LABEL_QUERIED.add(p));
  }
}

/* 规则行(玻璃卡) —— 学 NovaSched 的 rule-row
   .rule-shell 包一层是为了左滑删除: 删除按钮在壳里绝对定位,
   行本身用 transform 滑开。 */
function ruleRowHtml(pkg, profile, index, kind) {
  const a = appInfo(pkg);
  const tier = profile || "";
  const badgeCls = tier === "performance" ? "perf" : tier === "powersave" || tier === "powersave+" ? "save" : "balance";
  const badgeText = tier === "powersave+" ? "极限省电" : (ZH_PROFILE[tier] || tier || "未设置");
  const attr = kind === "touch" ? "data-touch-edit" : "data-policy-edit";
  const val = kind === "touch" ? (tier + " Hz") : badgeText;
  const badgeCls2 = kind === "touch" ? "balance" : badgeCls;
  return `<div class="rule-shell">
    <button class="swipe-delete" data-rule-del="${esc(pkg)}" type="button" tabindex="-1" aria-hidden="true">删除</button>
    <button class="rule-row g" data-role="course" data-color-index="${index % 6}" data-radius="18"
            type="button" ${attr}="${esc(pkg)}" aria-label="${esc(a.name)}，${esc(val)}">
      <span class="app-avatar rule-avatar" style="background:${avatarColor(a.name)}">${esc(a.initial)}</span>
      <span class="rule-copy"><b>${esc(a.name)}</b><small>${esc(pkg)}</small></span>
      <span class="mode-badge ${badgeCls2}">${esc(val)}</span>
      <svg class="chev" viewBox="0 0 24 24" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>
    </button>
  </div>`;
}
function ruleList(el, rows) {
  el.innerHTML = rows.map(r =>
    `<div class="rule-item"><span class="rpkg">${esc(r.k)}</span><span class="rval">${esc(ZH_PROFILE[r.v] || r.v)}</span>` +
    `<button class="rdel" data-k="${esc(r.k)}">×</button></div>`).join("");
}
function policyRules() {
  const rows = [];
  for (const k in POLICY_MAP) rows.push({ k, v: POLICY_MAP[k] });
  return rows;
}
/* 应用策略 + 专属采样率
   ----------
   两个列表都来自 apps.conf, 旧代码各读一次文件(两次 exec)。
   现在一次读、两次解析 —— KernelSU 里每次 exec 都要起 root shell,
   150~400ms, 省一次是一次。
   ------------------------------------------------------------ */
let APPS_CONF_CACHE = { at: 0, text: "" };
async function readAppsConf(force) {
  const now = Date.now();
  if (!force && APPS_CONF_CACHE.text && now - APPS_CONF_CACHE.at < 15000) return APPS_CONF_CACHE.text;
  APPS_CONF_CACHE = { at: now, text: await readFile(CFG + "/apps.conf") };
  return APPS_CONF_CACHE.text;
}
function invalidateAppsConf() { APPS_CONF_CACHE = { at: 0, text: "" }; }

/* 应用策略渲染
   ----------
   渲染 key 差分: 内容没变就不重建 DOM。
   否则每次状态轮询都会把规则列表整个换掉, 手指正按着编辑时列表会跳。
   ------------------------------------------------------------ */
function renderPolicyList() {
  const el = $("app-policy-list");
  if (!el) return;
  const rows = policyRules();
  const key = JSON.stringify([POLICY_QUERY, rows]);
  if (el.dataset.key === key) return;
  el.dataset.key = key;
  const q = POLICY_QUERY.trim().toLowerCase();
  const matched = rows.filter(r => {
    if (!q) return true;
    const a = appInfo(r.k);
    return (r.k + " " + a.name).toLowerCase().includes(q);
  });
  if (!matched.length) {
    el.innerHTML = rows.length
      ? `<div class="rule-empty">没有匹配的策略<br><small>换个关键词试试。</small></div>`
      : `<div class="rule-empty">还没有应用策略<br><small>点下方「添加应用策略」, 给游戏或视频应用单独设档。</small></div>`;
  } else {
    el.innerHTML = matched.map((r, i) => ruleRowHtml(r.k, r.v, i, "policy")).join("");
  }
  /* 新插入的玻璃行要注册到渲染器 */
  if (window.FallingGlass) window.FallingGlass.scan(el);
  setSec("policy-count", rows.length ? rows.length + " 条" : "未配置");
  bindRuleSwipe(el);
}

async function loadAppPolicy() {
  renderCounts();
  POLICY_MAP = {};
  const c = await readAppsConf();
  c.split("\n").forEach(l => {
    const t = l.trim();
    if (!t || t.startsWith("#") || t.includes("@") || t.startsWith("SCREEN_OFF_PROFILE")) return;
    const i = t.indexOf("=");
    if (i > 0) POLICY_MAP[t.slice(0, i).trim()] = t.slice(i + 1).trim();
  });
  loadAppLabels(Object.keys(POLICY_MAP));
  renderPolicyList();
  renderAppList();
}
/* 应用库: pm list packages 实测要 1~2 秒, 不能在首屏就跑。
   触控页的入口本来就写着「点刷新加载应用列表」, 按需加载。 */
let APPS_LOADED = false;
async function loadApps(force) {
  if (!force && APPS_LOADED) return;
  const u = (await exec(`pm list packages -3`)).stdout
    .split("\n").map(l => l.replace(/^package:/, "").trim()).filter(Boolean);
  const s = (await exec(`pm list packages -s`)).stdout
    .split("\n").map(l => l.replace(/^package:/, "").trim()).filter(Boolean);
  APP_USER = u; APP_SYS = s;
  APPS_LOADED = true;
  loadAppLabels([...u, ...s]);
  $("app-list").innerHTML = `<span class="muted">用户应用 ${u.length} · 系统应用 ${s.length}</span>`;
  renderAppList();
}

function renderAppList() {
  renderCounts();
  const list = APP_TAB === "user" ? APP_USER : APP_SYS;
  const kw = $("apps-search").value.trim().toLowerCase();
  const el = $("app-list");
  if (!list.length) { el.innerHTML = `<span class="muted">空 (点「刷新」加载)</span>`; return; }
  const rows = (kw ? list.filter(p => p.includes(kw)) : list).slice(0, 150);
  el.innerHTML = rows.map(p => {
    const cur = POLICY_MAP[p];
    const sel = `<select class="aset" data-pkg="${esc(p)}">` +
      `<option value="">不设置</option>` +
      ["balanced", "performance", "powersave", "powersave+", "game_medium"].map(x =>
        `<option value="${x}" ${cur === x ? "selected" : ""}>${ZH_PROFILE[x]}</option>`).join("") +
      `</select>`;
    return `<div class="app-row"><span class="aname" data-pkg="${esc(p)}" title="${esc(p)}">${esc(p)}</span>` +
      (cur ? `<span class="abadge">${ZH_PROFILE[cur]}</span>` : "") + sel + `</div>`;
  }).join("") + (rows.length < list.length ? `<span class="muted">仅显示前 ${rows.length} 条, 用搜索过滤</span>` : "");
  el.querySelectorAll(".aset").forEach(s => s.addEventListener("change", () => assignApp(s.dataset.pkg, s.value)));
}
async function assignApp(pkg, profile) {
  if (!SAFE_PKG.test(pkg)) return msg("非法包名");
  if (!profile) {
    await delRule(CFG + "/apps.conf", pkg);
    invalidateAppsConf();
    msg(`已取消: ${pkg}`);
  } else {
    await delRule(CFG + "/apps.conf", pkg);
    await exec(`printf '%s\\n' "${pkg}=${profile}" >> "${CFG}/apps.conf"`);
    invalidateAppsConf();
    msg(`已设置: ${pkg} → ${ZH_PROFILE[profile]}`);
  }
  await loadAppPolicy();
}
async function loadAppTouch() {
  renderCounts();
  const c = await readAppsConf();
  const rows = [];
  c.split("\n").forEach(l => {
    const t = l.trim();
    if (!t || t.startsWith("#")) return;
    const at = t.indexOf("@touch=");
    if (at < 1) return;
    rows.push({ k: t.slice(0, at), v: t.slice(at + 7) });
  });
  const el = $("app-touch-list");
  if (!el) return;
  const key = JSON.stringify(rows);
  if (el.dataset.key === key) return;
  el.dataset.key = key;
  if (!rows.length) {
    el.innerHTML = `<div class="rule-empty">还没有专属采样率<br><small>给某个 App 单独设触控采样率, 不影响它的 CPU 档位。</small></div>`;
  } else {
    el.innerHTML = rows.map((r, i) => {
      const a = appInfo(r.k);
      const code = r.v;
      const text = TOUCH_RATE_TEXT[code] || (code + " Hz");
      return `<div class="rule-shell">
        <button class="swipe-delete" data-touch-del="${esc(r.k)}" type="button" tabindex="-1" aria-hidden="true">删除</button>
        <button class="rule-row g" data-role="course" data-color-index="${(i + 3) % 6}" data-radius="18"
                type="button" data-touch-edit="${esc(r.k)}" aria-label="${esc(a.name)}，${esc(text)}">
          <span class="app-avatar rule-avatar" style="background:${avatarColor(a.name)}">${esc(a.initial)}</span>
          <span class="rule-copy"><b>${esc(a.name)}</b><small>${esc(r.k)}</small></span>
          <span class="mode-badge balance">${esc(text)}</span>
          <svg class="chev" viewBox="0 0 24 24" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>
        </button>
      </div>`;
    }).join("");
  }
  loadAppLabels(rows.map(r => r.k));
  if (window.FallingGlass) window.FallingGlass.scan(el);
  setSec("at-count", rows.length ? rows.length + " 条" : "未配置");
  bindRuleSwipe(el);
}
async function addAppTouch() {
  const pkg = $("at-pkg").value.trim(), code = $("at-code").value;
  if (!pkg) return msg("请输入包名");
  if (!SAFE_PKG.test(pkg)) return msg("包名含非法字符");
  await delTouchRule(CFG + "/apps.conf", pkg);
  await exec(`printf '%s\\n' "${pkg}@touch=${code}" >> "${CFG}/apps.conf"`);
  invalidateAppsConf();
  $("at-pkg").value = "";
  msg(`已添加: ${pkg} → ${code}`);
  await loadAppTouch();
}

/* ============================================================
   规则行交互 (学 NovaSched)
   ============================================================
   - 左滑露出删除按钮: 用 pointer 事件自己跟踪位移,
     不用 touchstart/touchmove(会和页面滚动打架)
   - 点击规则行进编辑弹窗, 而不是弹原生 confirm
   ============================================================ */
/* 触控采样率代码 -> 显示文本 */
const TOUCH_RATE_TEXT = {
  "1": "240Hz", "12c": "360Hz 一加", "c": "360Hz 真我",
  "360": "360Hz", "258": "600Hz"
};
let swipeState = null;
let suppressClickUntil = 0;

function bindRuleSwipe(el) {
  if (!el || el.dataset.swipeBound === "1") return;
  el.dataset.swipeBound = "1";
  el.addEventListener("pointerdown", event => {
    const shell = event.target.closest(".rule-shell");
    if (!shell || event.button > 0 || event.isPrimary === false) return;
    const row = shell.querySelector(".rule-row");
    if (!row) return;
    swipeState = { shell, row, id: event.pointerId, x: event.clientX, y: event.clientY, delta: 0, active: false };
  });
  el.addEventListener("pointermove", event => {
    if (!swipeState || event.pointerId !== swipeState.id) return;
    const dx = event.clientX - swipeState.x;
    const dy = event.clientY - swipeState.y;
    if (!swipeState.active) {
      if (Math.abs(dx) < 12 && Math.abs(dy) < 12) return;
      /* 竖向为主 -> 认为在滚动, 放弃滑动 */
      if (Math.abs(dy) > Math.abs(dx)) { swipeState = null; return; }
      swipeState.active = true;
      try { swipeState.row.setPointerCapture(event.pointerId); } catch (e) {}
    }
    event.preventDefault();
    swipeState.delta = dx;
    swipeState.row.style.transform = `translateX(${Math.min(0, dx + (swipeState.shell.classList.contains("swiped") ? -72 : 0))}px)`;
  });
  const end = event => {
    if (!swipeState || event.pointerId !== swipeState.id) return;
    const s = swipeState;
    swipeState = null;
    if (!s.active) return;
    const swiped = s.delta < -36;
    s.row.style.transform = "";
    s.shell.classList.toggle("swiped", swiped);
    if (swiped) suppressClickUntil = performance.now() + 220;
  };
  el.addEventListener("pointerup", end);
  el.addEventListener("pointercancel", end);
  el.addEventListener("click", event => {
    if (performance.now() < suppressClickUntil) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    const del = event.target.closest("[data-rule-del]");
    if (del) { deletePolicyRule(del.dataset.ruleDel); return; }
    const tdel = event.target.closest("[data-touch-del]");
    if (tdel) { deleteTouchRule(tdel.dataset.touchDel); return; }
    const edit = event.target.closest("[data-policy-edit]");
    if (edit) { openRuleEditor(edit.dataset.policyEdit); return; }
  }, true);
}

async function deletePolicyRule(pkg) {
  if (!SAFE_PKG.test(pkg)) return msg("非法包名");
  await delRule(CFG + "/apps.conf", pkg);
  invalidateAppsConf();
  msg("已删除策略");
  await loadAppPolicy();
  renderAppList();
}

async function deleteTouchRule(pkg) {
  if (!SAFE_PKG.test(pkg)) return msg("非法包名");
  await delTouchRule(CFG + "/apps.conf", pkg);
  invalidateAppsConf();
  msg("已删除专属采样率");
  await loadAppTouch();
}

/* ---------- 规则编辑弹窗 ---------- */
const POLICY_MODES = ["performance", "balanced", "powersave", "powersave+", "game_medium"];
let ruleEditMode = "balanced";
let ruleEditPkg = "";
/* 从应用库挑选: 打开弹窗时如果没给包名, 先拉应用列表让用户选 */
let rulePickList = null;

async function openRuleEditor(pkg) {
  const p = String(pkg || "");
  const existing = !!p && Object.prototype.hasOwnProperty.call(POLICY_MAP, p);
  ruleEditPkg = p;
  ruleEditMode = existing ? POLICY_MAP[p] : "balanced";
  if (!POLICY_MODES.includes(ruleEditMode)) ruleEditMode = "balanced";

  $("rule-eyebrow").textContent = existing ? "编辑策略" : "新建策略";
  $("rule-title").textContent = existing ? appInfo(p).name : "添加应用策略";
  const input = $("rule-pkg");
  input.value = existing ? p : "";
  input.readOnly = existing;
  $("rule-error").hidden = true;
  $("rule-delete").hidden = !existing;

  $("rule-chips").innerHTML = POLICY_MODES.map(m =>
    `<button type="button" data-chip="${m}" class="${m === ruleEditMode ? "active" : ""}">${ZH_PROFILE[m] || m}</button>`
  ).join("");
  $("rule-chips").querySelectorAll("[data-chip]").forEach(b =>
    b.addEventListener("click", () => {
      ruleEditMode = b.dataset.chip;
      $("rule-chips").querySelectorAll("[data-chip]").forEach(n =>
        n.classList.toggle("active", n === b));
    }));

  $("rule-modal").hidden = false;
  vib(8);

  /* 新建时给一个选应用的入口, 别让用户手打包名 */
  const pick = $("rule-pick");
  if (existing) {
    pick.hidden = true;
  } else {
    pick.hidden = false;
    pick.textContent = "从应用库选择…";
    pick.disabled = false;
    await ensureAppLibrary();
    renderRulePickList("");
    setTimeout(() => { input.focus(); }, 120);
  }
}

/* 应用库按需加载(pm list packages 慢), 供选包用 */
async function ensureAppLibrary() {
  if (APPS_LOADED) return;
  const pick = $("rule-pick");
  if (pick) { pick.disabled = true; pick.textContent = "加载应用列表…"; }
  try { await loadApps(true); } catch (e) { /* 忽略 */ }
  if (pick) { pick.disabled = false; pick.textContent = "从应用库选择…"; }
}
function renderRulePickList(query) {
  const box = $("rule-pick-list");
  if (!box) return;
  const q = String(query || "").trim().toLowerCase();
  const all = [...new Set([...APP_USER, ...APP_SYS])];
  const list = q ? all.filter(p => p.toLowerCase().includes(q)) : all;
  const rows = list.slice(0, 60);
  if (!rows.length) {
    box.innerHTML = `<div class="rule-empty">没有匹配的应用<br><small>可以手动输入包名。</small></div>`;
    return;
  }
  box.innerHTML = rows.map(p => {
    const a = appInfo(p);
    return `<button class="rule-row g" data-role="course" data-color-index="0" data-radius="18"
                    type="button" data-pick-pkg="${esc(p)}">
      <span class="app-avatar rule-avatar" style="background:${avatarColor(a.name)}">${esc(a.initial)}</span>
      <span class="rule-copy"><b>${esc(a.name)}</b><small>${esc(p)}</small></span>
    </button>`;
  }).join("") + (list.length > rows.length
    ? `<span class="muted" style="font-size:11.5px">仅显示前 ${rows.length} 条, 用搜索缩小范围</span>` : "");
  if (window.FallingGlass) window.FallingGlass.scan(box);
}

function closeRuleEditor() {
  $("rule-modal").hidden = true;
  const panel = $("rule-pick-panel");
  if (panel) panel.hidden = true;
}

async function saveRuleFromEditor() {
  const input = $("rule-pkg");
  const pkg = input.value.trim();
  const err = $("rule-error");
  if (!SAFE_PKG.test(pkg)) {
    err.hidden = false;
    err.textContent = "请输入有效的主应用包名，例如 com.tencent.tmgp.sgame。";
    return;
  }
  err.hidden = true;
  await delRule(CFG + "/apps.conf", pkg);
  await exec(`printf '%s\\n' "${pkg}=${ruleEditMode}" >> "${CFG}/apps.conf"`);
  invalidateAppsConf();
  closeRuleEditor();
  msg(`已保存: ${appInfo(pkg).name} → ${ZH_PROFILE[ruleEditMode] || ruleEditMode}`);
  await loadAppPolicy();
  renderAppList();
}

async function loadLog() {
  $("log-view").textContent = (await exec(`tail -n 60 "${LOGF}" 2>/dev/null`)).stdout || "(空)";
}
async function clearLog() {
  await exec(`echo "" > "${LOGF}"`);
  msg("日志已清空");
  await loadLog();
}

async function loadDaemon() {
  const r = await exec(`pgrep -f falling_daemon | head -1`);
  const on = !!(r.stdout && r.stdout.trim());
  const pill = $("daemon-pill");
  if (pill) pill.setAttribute("data-state", on ? "running" : "offline");
  const st = $("daemon-state");
  if (st) st.textContent = on ? "守护运行中" : "守护未运行";
  const st2 = $("daemon-state2");
  if (st2) st2.textContent = on ? "运行中" : "未运行";
  const sw = $("daemon-toggle");
  if (sw) sw.setAttribute("aria-checked", on ? "true" : "false");
}
async function setDaemon(on) {
  await setOpt("daemon", on ? 1 : 0);
  if (on) {
    const r = await exec(`pgrep -f falling_daemon | head -1`);
    if (!r.stdout.trim()) await exec(`nohup sh ${MOD}/bin/falling_daemon >/dev/null 2>&1 &`);
    msg("守护已启动");
  } else {
    await exec(`pkill -f falling_daemon`);
    msg("守护已停止 (重启后仍按开关决定)");
  }
  await loadDaemon();
}

// role=switch 的按钮绑定: 内部用 aria-checked 表示状态
function bindSwitch(id, onChange) {
  const el = $(id);
  if (!el) return;
  el.addEventListener("click", async () => {
    const next = el.getAttribute("aria-checked") !== "true";
    const r = onChange ? await onChange(next) : next;
    const final = (r === false) ? false : next;
    el.setAttribute("aria-checked", final ? "true" : "false");
    vib(final ? 12 : 8);
  });
}
const execT = (cmd, ms = 15000) => {
  let to = null;
  const timer = new Promise((_, rej) => { to = setTimeout(() => rej(new Error("命令执行超时")), ms); });
  const p = Promise.race([exec(cmd), timer]);
  p.catch(() => {}).finally(() => clearTimeout(to));
  return p;
};

async function loadSysInfo() {
  $("s-kern").textContent = (await sh(`uname -r`)) || "--";
  $("s-ver").textContent = (await sh(`grep '^version=' "${MOD}/module.prop" | cut -d= -f2`)) || "--";
  $("s-fp").textContent = (await sh(`getprop ro.build.fingerprint`)) || "--";
  $("s-selinux").textContent = (await sh(`getenforce`)) || "--";
}
function fillTemps(cpu, gpu, batt, cyc) {
  const show = (el, v) => { const x = $(el); if (x) x.textContent = v > 0 ? (v / 1000).toFixed(0) + "°" : "--"; };
  show("t-cpu", cpu);
  show("t-gpu", gpu);
  show("t-batt", batt);
  const tt = $("t-cycle"); if (tt) tt.textContent = cyc;
  const ts = $("t-time");
  if (ts) ts.textContent = new Date().toLocaleTimeString("zh-CN", { hour12: false });
}
async function loadTemps() {
  const out = (await exec(`for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat $z/type 2>/dev/null); [ -n "$t" ] || continue
    case "$t" in cpu-*|soc-*) echo "cpu $(cat $z/temp 2>/dev/null)";; gpu*) echo "gpu $(cat $z/temp 2>/dev/null)";; esac
  done`)).stdout;
  let cpu = -1, gpu = -1;
  out.split("\n").forEach(l => {
    const a = l.trim().split(/\s+/);
    if (a.length < 2) return;
    const v = +a[1];
    if (!(v > 0)) return;
    if (a[0] === "cpu") cpu = Math.max(cpu, v);
    if (a[0] === "gpu") gpu = Math.max(gpu, v);
  });
  const batt = +((await exec(`cat /sys/class/power_supply/battery/temp 2>/dev/null`)).stdout.trim()) || -1;
  const cyc = ((await exec(`cat /sys/class/power_supply/battery/cycle_count 2>/dev/null`)).stdout.trim()) ||
              ((await exec(`cat /sys/class/power_supply/battery/device/cycle_count 2>/dev/null`)).stdout.trim()) || "--";
  fillTemps(cpu, gpu, batt, cyc);
}
/* ============ 外观: QQ 风格, 浅色/深色两模式 ============ */
const THEMES = ["light", "dark"];
const ZH_THEME = { light: "浅色", dark: "深色" };

/* 液态玻璃开关状态(与 glass-liquid.js 共用同一个 localStorage 键) */
const GLASS_KEY = "falling.glass.v3";
function readGlassPref() {
  try {
    const v = localStorage.getItem(GLASS_KEY);
    return v === "off" ? "off" : "on";
  } catch (e) { return "on"; }
}
function writeGlassPref(v) {
  try { localStorage.setItem(GLASS_KEY, v); } catch (e) { /* 宿主可能禁存储 */ }
}

function applyAppearance(theme) {
  const t = THEMES.includes(theme) ? theme : "light";
  document.body.dataset.theme = t;
  document.querySelectorAll("#theme-picker .theme-swatch").forEach(b =>
    b.classList.toggle("active", b.dataset.theme === t));
  /* 玻璃引擎的配色跟随主题: 壁纸要重画, 所有玻璃面要重绘 */
  if (window.FallingGlass) {
    window.FallingGlass.setTheme(t);
    window.FallingGlass.invalidate(320);
  }
}
async function loadAppearance() {
  applyAppearance((await sysOpt("theme")) || "light");
}
async function setAppearance(val) {
  await setOpt("theme", val);
  applyAppearance(val);
  msg(`外观已切换: ${ZH_THEME[val] || val}`);
}

/* 液态玻璃开关: 关掉时整个摘掉 WebGL 画布, 退回 CSS 半透明 */
function applyGlass(on) {
  const g = window.FallingGlass;
  if (g) g.setEnabled(on);
  else document.documentElement.setAttribute("data-glass", on ? "on" : "off");
  writeGlassPref(on ? "on" : "off");
  const note = $("glass-note");
  if (note) {
    note.textContent = !on ? "已关闭, 退回半透明"
      : (g && g.runtime() === "WebGL") ? "折射、模糊与边缘色散"
      : "本机不支持 WebGL, 已降级为模糊";
  }
}


/* ============ v8.0 ZRAM 内存优化 ============ */
const ZRAM_XML = MOD + "/odm/etc/oplus_mm_config.xml";
const ZRAM_KEYS = [
  ["disk_size_mb", "zram大小 MB"],
  ["increase_limit", "扩展增量 MB"],
  ["comp_algorithm", "压缩算法"],
  ["limit_size", "可用上限 MB"],
  ["vm_swappiness", "vm_swappiness"],
  ["direct_swappiness", "direct_swappiness"]
];
let zramXml = "", zramTab = "16g";

/* ZRAM 数据一次读完
   ----------
   旧实现分三次 exec: loadZram 一次、loadZramEditor 里还有
   「文件是否存在」「系统目标是否存在」「MemTotal」三次 sh(),
   加上 readFile(ZRAM_XML) 一次 —— 进设置页要 5 次 root shell。
   现在合并成一次, 且带缓存: 30 秒内重复进设置页不再 exec。
   ------------------------------------------------------------ */
let ZRAM_CACHE = { at: 0, data: null };
const ZRAM_TTL = 30000;

async function loadZram(force) {
  const el = $("zram-dash");
  if (!el) return;
  const now = Date.now();
  if (!force && ZRAM_CACHE.data && now - ZRAM_CACHE.at < ZRAM_TTL) {
    renderZram(ZRAM_CACHE.data);
    return ZRAM_CACHE.data;
  }
  const out = await sh(`echo "size=$(cat /sys/block/zram0/disksize 2>/dev/null)";
echo "alg=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)";
echo "swap=$(cat /proc/oplus_mem/swappiness_para 2>/dev/null | tr '\\n' '|')";
echo "mem=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')";
echo "mod=$( [ -f "${ZRAM_XML}" ] && echo yes || echo no)";
echo "sys=$( [ -f /odm/etc/oplus_mm_config.xml ] && echo yes || echo no)"`);
  const g = k => { const m = new RegExp("^" + k + "=(.*)$", "m").exec(out); return m ? m[1] : ""; };
  const sizeB = +g("size") || 0;
  const sizeMB = sizeB > 0 ? Math.round(sizeB / 1024 / 1024) : 0;
  const algM = /\[([^\]]+)\]/.exec(g("alg"));
  const alg = algM ? algM[1] : (g("alg").trim().split(/\s+/)[0] || "--");
  const swap = g("swap");
  const vm = /vm_swappiness\s*:\s*(\d+)/.exec(swap)?.[1] || "--";
  const dir = /direct_swappiness\s*:\s*(\d+)/.exec(swap)?.[1] || "--";
  const memKB = +g("mem") || 0;
  const tier = memKB >= 23 * 1024 * 1024 ? "24G" : memKB >= 15 * 1024 * 1024 ? "16G" : "12G";
  const data = {
    sizeMB, alg, vm, dir, memKB, tier,
    fileOk: g("mod") === "yes", sysOk: g("sys") === "yes"
  };
  ZRAM_CACHE = { at: now, data };
  renderZram(data);
  return data;
}

function renderZram(d) {
  const el = $("zram-dash");
  if (el) {
    el.innerHTML =
      row("当前大小", d.sizeMB ? d.sizeMB + " MB" : "--") +
      row("压缩算法", d.alg) +
      row("vm_swappiness", d.vm) +
      row("direct_swappiness", d.dir) +
      row("物理内存", d.memKB ? Math.round(d.memKB / 1024 / 1024) + " GB" : "--") +
      row("匹配档位", d.tier);
  }
  const tier = $("zram-tier");
  if (tier) tier.textContent = d.memKB ? Math.round(d.memKB / 1024 / 1024) + " GB 物理内存" : "--";
  const probe = $("zram-probe");
  if (probe) {
    probe.innerHTML =
      row("模块 XML", d.fileOk ? "存在(可编辑)" : "缺失(仅只读)") +
      row("系统目标", d.sysOk ? "存在(重启挂载覆盖)" : "不存在(挂载跳过)");
  }
}

function zramVal(seg, key) {
  const m = new RegExp("<" + seg + ">[\\s\\S]*?<" + key + ">([^<]*)</" + key + ">[\\s\\S]*?</" + seg + ">").exec(zramXml);
  return m ? m[1].trim() : "";
}

/* ZRAM 编辑器: 只有用户真的展开这一块时才读 XML
   (默认 hidden, 进设置页不该为了一个折叠区去读整个配置文件) */
let ZRAM_EDITOR_LOADED = false;
async function loadZramEditor(force) {
  if (!force && ZRAM_EDITOR_LOADED) return;
  const d = await loadZram();
  if (!d.fileOk) { $("zram-editor").hidden = true; ZRAM_EDITOR_LOADED = true; return; }
  zramXml = (await readFile(ZRAM_XML)) || "";
  if (!zramXml.includes("<memory_")) { $("zram-editor").hidden = true; ZRAM_EDITOR_LOADED = true; return; }
  zramTab = (d.memKB >= 23 * 1024 * 1024 ? "24g" : d.memKB >= 15 * 1024 * 1024 ? "16g" : "12g");
  $("zram-editor").hidden = false;
  ZRAM_EDITOR_LOADED = true;
  renderZramParams();
}
function renderZramParams() {
  document.querySelectorAll("#zram-editor-tabs .seg-btn").forEach(b =>
    b.classList.toggle("active", b.dataset.zramtab === zramTab));
  const seg = "memory_" + zramTab;
  const grid = $("zram-params");
  grid.innerHTML = ZRAM_KEYS.map(([k, label]) => {
    const v = zramVal(seg, k);
    if (k === "comp_algorithm") {
      const algs = ["lz4", "zstd", "lzo", "lzo-rle", "lz4hc"];
      return `<div class="tune-field"><label>${label}</label>` +
        `<select class="sel" data-zkey="${k}">` +
        algs.map(a => `<option value="${a}" ${a === v ? "selected" : ""}>${a}</option>`).join("") +
        `</select></div>`;
    }
    return `<div class="tune-field"><label>${label}</label>` +
      `<input class="inp" data-zkey="${k}" value="${esc(v)}" inputmode="numeric"></div>`;
  }).join("");
}

async function saveZram() {
  const seg = "memory_" + zramTab;
  if (!zramXml.includes("<" + seg + ">")) { msg("该内存档缺失, 无法保存"); return; }
  const vals = {};
  document.querySelectorAll("#zram-params [data-zkey]").forEach(i => {
    vals[i.dataset.zkey] = i.dataset.zkey === "comp_algorithm"
      ? i.value.trim() : (i.value.replace(/[^\d-]/g, "") || "0");
  });
  let out = zramXml.replace(
    new RegExp("(<" + seg + ">[\\s\\S]*?<zram0>)([\\s\\S]*?)(</zram0>[\\s\\S]*?<zram_opt>)([\\s\\S]*?)(</zram_opt>[\\s\\S]*?</" + seg + ">)"),
    (m, a, b, c, d, e) => a + zram0Block(b, vals) + c + zramOptBlock(d, vals) + e
  );
  const ok = await writeFile(ZRAM_XML, out);
  if (!ok) { msg("保存失败"); return; }
  zramXml = out;
  msg("ZRAM 配置已保存 (重启挂载生效)");
  await loadZram();
}
function zram0Block(b, vals) {
  const ks = ["disk_size_mb", "increase_limit", "comp_algorithm", "limit_size"];
  return ks.map(k => `            <${k}>${vals[k] ?? zramKey(b, k)}</${k}>\n`).join("");
}
function zramOptBlock(d, vals) {
  const ks = ["vm_swappiness", "direct_swappiness"];
  return ks.map(k => `            <${k}>${vals[k] ?? zramKey(d, k)}</${k}>\n`).join("");
}
function zramKey(block, key) {
  const m = new RegExp("<" + key + ">([^<]*)</" + key + ">").exec(block);
  return m ? m[1] : "0";
}


/* v3.1.0: 分区标题右侧的状态徽标(学 NovaSched 的 sec-time) */
function setSec(id, v) { const e = $(id); if (e) e.textContent = v; }

function renderCounts() {
  // 事件条数
  const ev = $("event-log");
  if (ev) {
    const n = ev.textContent.trim() ? ev.textContent.trim().split("\n").filter(Boolean).length : 0;
    setSec("event-count", n ? n + " 条" : "暂无");
  }
  // 应用策略条数(由 renderPolicyList 维护, 这里不重复写)
  // 专属采样率条数(由 loadAppTouch 维护)
  // 应用库条数
  const apl = $("app-list");
  if (apl) {
    const n = apl.querySelectorAll(".app-row").length;
    setSec("app-count", n ? n + " 个" : "点刷新加载");
  }
  // 决策状态
  const sm = document.querySelector("#smart-info");
  if (sm) {
    const t = sm.textContent.match(/当前档位\s*([^ ]+)/);
    if (t) setSec("decision-state", t[1]);
  }
  // 游戏调度状态
  const gm = $("game-mode-seg");
  if (gm) {
    const act = gm.querySelector("button.active");
    if (act) setSec("gmode-state", act.textContent.trim());
  }
  // 触控状态
  const ts = $("touch-state-top");
  if (ts) {
    const sw = $("touch-toggle");
    ts.textContent = sw && sw.getAttribute("aria-checked") === "true" ? "已启用" : "已停用";
  }
}

/* ============================================================
   导航: 4 个平级 page + 胶囊 dock
   借鉴 NovaSched 的做法: 页面是同级的 section, 切换时双向播放进/出动画,
   每个 page 保留自己的滚动位置, dock 指示器滑动跟随。
   ============================================================ */
const PAGE_IDS = ["overview", "schedule", "touch", "settings"];
let currentPage = "overview";
const pageScroll = new Map();

const motionQuery = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)");
const reducedMotion = () => !!motionQuery && motionQuery.matches;
const motions = new Map();
let stopPageMotion = null;

// 统一的动效所有权: 新动效开始前先取消旧的, 避免叠加
function ownedMotion(el, frames, options, complete) {
  if (motions.has(el)) motions.get(el).cancel();
  let animation = null, timer = 0, settled = false;
  const ctl = {
    cancel: () => settle(false),
    finish: () => settle(true)
  };
  function settle(finished) {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    if (motions.get(el) === ctl) motions.delete(el);
    if (animation) {
      animation.onfinish = null;
      animation.oncancel = null;
      try { animation.cancel(); } catch (e) {}
    }
    complete && complete(finished);
  }
  if (reducedMotion() || !el || typeof el.animate !== "function") {
    settle(true);
    return ctl;
  }
  motions.set(el, ctl);
  try {
    animation = el.animate(frames, options);
    animation.onfinish = ctl.finish;
    animation.oncancel = ctl.cancel;
    timer = setTimeout(ctl.finish, (options.duration || 0) + 80);
  } catch (e) {
    settle(true);
  }
  return ctl;
}

// 页面切换动画: 旧页向左滑出、新页从右侧滑入(反向则相反)
function animatePageSwitch(prev, next, forward) {
  if (stopPageMotion) stopPageMotion();
  const incoming = $("page-" + next);
  const outgoing = $("page-" + prev);
  if (!incoming || !outgoing || reducedMotion() || typeof incoming.animate !== "function") return;

  const main = $("main");
  // 滚动位置不��零时只做淡入, 不做横向滑动(避免内容跳动)
  if (main && main.scrollTop > 0) {
    ownedMotion(incoming, [{ opacity: .45 }, { opacity: 1 }],
      { duration: 220, easing: "ease-out", fill: "both" });
    return;
  }

  const duration = 360, easing = "cubic-bezier(.22,.8,.25,1)";
  let out = null, inn = null, timer = 0, done = 0, settled = false;
  const finish = () => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    [out, inn].forEach(a => {
      if (!a) return;
      a.onfinish = null;
      a.oncancel = null;
      try { a.cancel(); } catch (e) {}
    });
    outgoing.classList.remove("leaving");
    if (stopPageMotion === finish) stopPageMotion = null;
  };
  stopPageMotion = finish;
  outgoing.classList.add("leaving");
  try {
    out = outgoing.animate(
      [{ transform: "none", opacity: 1 }, { transform: `translateX(${forward ? "-12%" : "12%"})`, opacity: 0 }],
      { duration, easing, fill: "both" });
    inn = incoming.animate(
      [{ transform: `translateX(${forward ? "18%" : "-18%"})`, opacity: 0 }, { transform: "none", opacity: 1 }],
      { duration, easing, fill: "both" });
    const ended = () => { if (++done === 2) finish(); };
    out.onfinish = ended;
    inn.onfinish = ended;
    out.oncancel = finish;
    inn.oncancel = finish;
    timer = setTimeout(finish, duration + 100);
  } catch (e) {
    finish();
  }
}

function setPage(page) {
  if (PAGE_IDS.indexOf(page) < 0) page = "overview";
  const prev = currentPage;
  const changed = prev !== page;
  if (!changed) return;

  const main = $("main");
  if (main) pageScroll.set(prev, main.scrollTop || 0);

  currentPage = page;

  document.querySelectorAll(".page").forEach(n => {
    n.classList.toggle("active", n.id === "page-" + page);
    n.setAttribute("aria-hidden", String(n.id !== "page-" + page));
    n.inert = n.id !== "page-" + page;
  });

  const index = PAGE_IDS.indexOf(page);
  document.querySelectorAll(".dock button").forEach((b, i) => {
    if (i === index) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  });
  const dock = document.querySelector(".dock");
  if (dock) dock.style.setProperty("--tab-index", String(index));
  document.documentElement.dataset.page = page;

  if (main) main.scrollTop = pageScroll.get(page) || 0;
  animatePageSwitch(prev, page, index > PAGE_IDS.indexOf(prev));

  /* 通知玻璃引擎: 新页面的玻璃面要重新登记并重绘
     (旧页面的面在 measure() 里因为 .page 不再 active 被自动释放) */
  window.dispatchEvent(new CustomEvent("nova:page", {
    detail: { animate: changed && !reducedMotion() }
  }));

  // 按需加载: 离开的页面的数据不再刷新
  loadForPage(page);
  vib(8);
}

// 各页按需加载
function loadForPage(page) {
  if (page === "overview") { loadStatus(); }
  if (page === "schedule") {
    loadStatus();
    loadGameMode();
    loadTendency();
    loadSchedNodes();
    loadSmartDetail();
  }
  if (page === "touch") { loadTouch(); loadAppPolicy(); loadAppTouch(); }
  /* 设置页: 日志与 ZRAM 仪表都是慢变数据, 有 30s 缓存,
     不再每次切页都发起 3 次 root shell(旧行为在真机上卡 1~2 秒)。
     ZRAM 参数编辑器默认折叠, 只有展开时才读 XML。 */
  if (page === "settings") {
    loadLog();
    loadZram();
  }
}

// 兼容旧的 openPage / goHome 调用(内部逻辑已改为平级 page)
function openPage(id) {
  const map = {
    "sub-scheme": "schedule",
    "sub-touch": "touch",
    "sub-tools": "settings",
    "sub-cpu": "overview",
    "sub-gpu": "overview",
    "sub-zram": "settings",
    "sub-thermal": "overview"
  };
  setPage(map[id] || "overview");
}
function goHome() { setPage("overview"); }

/* v2.1 调度层节点探测: sh lib/sched.sh probe -> "KEY path ok value|missing" */
// 分簇占用: cluster0/1/2 按 policy 顺序; -1 表示该档无基线或本机无此簇
const CL_NAMES = ["小核", "中核", "大核"];
function clusterText(sm) {
  const raw = [sm.cluster0, sm.cluster1, sm.cluster2];
  const vals = raw.map(v => (v === undefined || v === "" || v === "-1") ? null : +v);
  const used = vals.filter(v => v !== null);
  if (!used.length) return "--";
  const off = vals[2] !== null ? 0 : (vals[1] !== null ? 1 : 2);
  const parts = [];
  vals.forEach((v, i) => { if (v !== null) parts.push(CL_NAMES[i + off] + " " + v + "%"); });
  return parts.join(" · ");
}
function primeText(sm) {
  const v = sm.prime;
  if (v === undefined || v === "" || v === "-1") return "--";
  return v + "%" + (+v >= 90 ? "（吃满）" : (+v >= 70 ? "（偏高）" : ""));
}
function fmtDur(sec) {
  sec = +sec || 0;
  if (sec < 60) return sec + " 秒";
  if (sec < 3600) return Math.floor(sec / 60) + " 分 " + (sec % 60) + " 秒";
  return Math.floor(sec / 3600) + " 小时 " + Math.floor((sec % 3600) / 60) + " 分";
}

// 决策历史 / 驻留统计 / 守护存活: 只在调度页打开时取一次, 不参与 2s 轮询
async function loadSmartDetail() {
  const box = $("smart-stats");
  if (!box) return;
  const out = await sh(`echo "=alive=$(cat ${CFG}/runtime/daemon.alive 2>/dev/null)";
echo "=rst=$(cat ${CFG}/runtime/daemon.restarts 2>/dev/null)";
echo "=st=$(cat ${CFG}/runtime/smart.stats 2>/dev/null | tr '\\n' '|')";
echo "=tr=$(tail -n 8 ${CFG}/runtime/smart.trace 2>/dev/null | tr '\\n' '|')"`);
  const pick = k => { const m = new RegExp("^=" + k + "=(.*)$", "m").exec(out); return m ? m[1] : ""; };

  // 驻留统计
  const st = {};
  String(pick("st")).split("|").forEach(l => {
    const i = l.indexOf("=");
    if (i > 0) st[l.slice(0, i).trim()] = +l.slice(i + 1) || 0;
  });
  const keys = Object.keys(st).filter(k => st[k] > 0).sort((a, b) => st[b] - st[a]);
  const total = keys.reduce((a, k) => a + st[k], 0);
  box.innerHTML = keys.length
    ? keys.map(k => row(ZH_PROFILE[k] || k, fmtDur(st[k]) + " · " + Math.round(st[k] * 100 / total) + "%")).join("")
      + row("统计时长", fmtDur(total))
    : row("驻留统计", "还没换过档，或本机刚启动");

  // 决策历史 -> 决策链时间轴(原创: 把原始行变成因果可视化)
  const tr = String(pick("tr")).split("|").filter(x => x.trim());
  renderDecisionTimeline(tr.join("\n"));

  // 运行状态
  const dv = $("daemon-info");
  if (dv) {
    const al = String(pick("alive")).trim().split(/\s+/);
    const pid = al[0] || "", up = al[1] || "";
    const rs = +pick("rst") || 0;
    dv.innerHTML =
      row("后台守护", pid ? "运行中 (pid " + pid + ")" : "未运行") +
      row("已运行", up ? fmtDur(up) : "--") +
      row("异常重启", rs ? rs + " 次" : "无") +
      row("调度引擎", "每 5 秒决策一次，息屏 15 秒") +
      row("采集开销", "温度 / 整机与分簇占用 / 帧率 全部内建读取，无子进程");
  }
}

async function loadSchedNodes() {
  const box = $("sched-nodes"), sum = $("sched-layer-sum"), raw = $("sched-node-raw");
  if (!box) return;
  box.innerHTML = '<span class="muted">探测中…</span>';
  const r = await execT(`sh ${MOD}/lib/sched.sh probe 2>/dev/null`, 20000);
  const lines = String(r.stdout || "").split("\n").map(l => l.trim()).filter(Boolean);
  if (!lines.length) {
    box.innerHTML = '<span class="muted">探测失败：调度层脚本不可用</span>';
    if (sum) sum.textContent = "--";
    return;
  }
  let ok = 0, miss = 0;
  const missKeys = [];
  for (const l of lines) {
    const p = l.split(/\s+/);
    if (p[2] === "ok") ok++;
    else {
      miss++;
      if (p[0]) missKeys.push(p[0]);
    }
  }
  const sched = (await cat(CFG + "/sched_profile")) || "balance";
  box.innerHTML =
    row("可用节点", ok + " 项") +
    row("本机缺失", miss ? miss + " 项（自动跳过）" : "无") +
    row("当前调度策略", ZH_SCHED[sched] || sched);
  if (sum) sum.textContent = miss ? `可用 ${ok} · 缺失 ${miss}` : `全部可用（${ok} 项）`;
  if (raw) {
    raw.hidden = false;
    raw.textContent = missKeys.length
      ? "本机缺失（内核无此节点，模块不会写）：\n" + missKeys.join("\n")
      : "全部节点可用";
  }
}

/* ============================================================
   原创可视化 1 · 帧率闭环仪表
   ------------------------------------------------------------
   NovaSched 的 engine-meter 是「一条静态进度条」, 表达单一度量。
   调度闭环是多维的: 追帧压力 / 执行器档位 / 帧率达标率 / 大核占用 /
   温控降额。所以做成「压力环 + 三段条 + 档位刻度」。

   压力环用 SVG 描边: dasharray 是周长, dashoffset 越接近周长弧越短。
   压力越高弧越长, 颜色越暖(冷→暖→热), 与调度色板一致。
   ============================================================ */
const LOOP_RING_C = 2 * Math.PI * 33;   // r=33 的周长

// 压力 -> 颜色: 冷(蓝) / 暖(橙) / 热(红)
function pressColor(p) {
  if (p >= 75) return "var(--press-hot)";
  if (p >= 45) return "var(--press-warm)";
  return "var(--press-cool)";
}

function renderLoop(state) {
  const arc = $("loop-arc");
  const pressEl = $("loop-press");
  const fpsEl = $("loop-fps");
  const primeEl = $("loop-prime");
  const psiEl = $("loop-psi");
  const ratioEl = $("loop-ratio");
  const steps = $("exec-steps");
  const stateEl = $("loop-state");
  if (!arc) return;

  // loop.state: ema=<帧率EMA> press=<压力> level=<执行器档位>
  const ls = state.loop || {};
  const press = ls.press !== undefined && ls.press !== "" ? +ls.press : -1;
  const level = ls.level !== undefined && ls.level !== "" ? +ls.level : -1;
  const ema = ls.ema !== undefined && ls.ema !== "" ? +ls.ema : -1;

  // smart.state 里的即时信号
  const sm = state.sm || {};
  const fps = sm.fps !== undefined && sm.fps !== "" ? +sm.fps : -1;
  const prime = sm.prime !== undefined && sm.prime !== "" ? +sm.prime : -1;
  const psi = sm.psi !== undefined && sm.psi !== "" ? +sm.psi : -1;
  const ratio = state.ratio !== undefined ? state.ratio : 100;

  // 压力未知时用「帧率 + 大核」合成一个参考值, 让环不至于永远空着
  let p = press;
  if (p < 0) {
    if (fps >= 0 || prime >= 0) {
      const f = fps >= 0 ? Math.max(0, 100 - fps) : 50;
      const pr = prime >= 0 ? Math.max(0, prime - 60) : 0;
      p = Math.min(100, Math.round(f * 0.7 + pr * 0.6));
    } else {
      p = 0;
    }
  }

  arc.setAttribute("stroke-dasharray", LOOP_RING_C.toFixed(1));
  arc.setAttribute("stroke-dashoffset", (LOOP_RING_C * (1 - p / 100)).toFixed(1));
  arc.style.stroke = pressColor(p);
  // 显示实际用于画环的那个值(有 loop.state 就是真压力,
  // 没有就用帧率+大核合成的参考值) —— 数字与弧长必须一致
  if (pressEl) pressEl.textContent = String(p);

  // 帧率达标率
  if (fpsEl) fpsEl.textContent = fps >= 0 ? fps + "%" : "--";
  const fb = $("loop-fps-bar");
  if (fb) {
    fb.style.width = (fps >= 0 ? Math.min(100, fps) : 0) + "%";
    fb.style.background = fps < 60 ? "var(--press-hot)" : fps < 85 ? "var(--press-warm)" : "var(--press-cool)";
  }
  // 大核占用
  if (primeEl) primeEl.textContent = prime >= 0 ? prime + "%" : "--";
  const pb = $("loop-prime-bar");
  if (pb) {
    pb.style.width = (prime >= 0 ? Math.min(100, prime) : 0) + "%";
    pb.style.background = prime >= 90 ? "var(--press-hot)" : prime >= 70 ? "var(--press-warm)" : "var(--press-cool)";
  }
  // CPU 争用(PSI cpu some avg10): 任务因抢不到 CPU 而等待的时间占比
  if (psiEl) psiEl.textContent = psi >= 0 ? psi + "%" : "--";
  const psib = $("loop-psi-bar");
  if (psib) {
    psib.style.width = (psi >= 0 ? Math.min(100, psi) : 0) + "%";
    psib.style.background = psi >= 40 ? "var(--press-hot)" : psi >= 20 ? "var(--press-warm)" : "var(--press-cool)";
  }
  // 温控降额: 100% 是不降额, 所以条的长度表示「降了多少」而不是「剩多少」
  if (ratioEl) ratioEl.textContent = ratio >= 100 ? "全速" : ratio + "%";
  const rb = $("loop-ratio-bar");
  if (rb) {
    const cut = ratio >= 100 ? 0 : 100 - ratio;
    rb.style.width = cut + "%";
    rb.style.background = cut > 30 ? "var(--press-hot)" : cut > 10 ? "var(--press-warm)" : "var(--press-cool)";
  }

  // 执行器档位刻度: 5 格, 已达成的格填充, 当前格高亮
  if (steps) {
    const spans = steps.querySelectorAll("span");
    spans.forEach((s, i) => {
      s.classList.toggle("on", level >= 0 && i <= level);
      s.classList.toggle("cur", level >= 0 && i === level);
    });
  }

  if (stateEl) {
    stateEl.textContent = level >= 0 ? ("执行器 L" + level) : "等待采样";
  }
  const explain = $("loop-explain");
  if (explain) {
    explain.textContent = level >= 0
      ? ("L" + level + " · " + (level <= 1 ? "偏保守" : level <= 2 ? "均衡" : level <= 3 ? "偏激进" : "追帧模式"))
      : "帧率富余则收紧，帧率不足则放开";
  }
}

/* ============================================================
   原创可视化 2 · 分簇热力
   ------------------------------------------------------------
   整机占用看不出瓶颈在哪: 小核吃满+大核空转 与 三簇各半 是两回事。
   三条并列的条形, 一眼看出谁在忙。
   ============================================================ */
function renderClusterHeat(sm) {
  const raw = [sm.cluster0, sm.cluster1, sm.cluster2];
  const vals = raw.map(v => (v === undefined || v === "" || v === "-1") ? null : +v);
  // 三簇不一定都存在(本机可能只有两簇), 按实际存在的簇重新命名
  const off = vals[2] !== null ? 0 : (vals[1] !== null ? 1 : 2);
  const names = ["小核", "中核", "大核"];
  for (let i = 0; i < 3; i++) {
    const v = vals[i];
    const bar = $("cl" + i + "-bar");
    const val = $("cl" + i + "-val");
    const nameEl = document.querySelectorAll(".cluster-name")[i];
    if (nameEl) nameEl.textContent = v === null ? "--" : names[i + off];
    if (val) val.textContent = v === null ? "--" : v + "%";
    if (bar) {
      bar.style.width = (v === null ? 0 : Math.min(100, v)) + "%";
      bar.style.background = v === null ? "var(--press-cool)"
        : v >= 90 ? "var(--press-hot)" : v >= 70 ? "var(--press-warm)" : "var(--press-cool)";
    }
  }
  const st = $("cluster-state");
  if (st) {
    const known = vals.filter(v => v !== null);
    st.textContent = known.length ? known.length + " 簇可用" : "暂无基线";
  }
}

/* ============================================================
   原创可视化 3 · 决策链时间轴
   ------------------------------------------------------------
   「为什么又降档了」—— 用户真正想看的是因果链, 不是一行行原始日志。
   把 smart.trace 解析成时间轴: 换档方向 + 原因 + 当时的信号。
   ============================================================ */
function renderDecisionTimeline(raw) {
  const el = $("smart-trace");
  if (!el) return;
  const lines = String(raw || "").split("\n").map(l => l.trim()).filter(Boolean);
  if (!lines.length) {
    el.innerHTML = '<div class="empty-hint">还没有换过档<small>每次换档才记一条</small></div>';
    const c = $("trace-count");
    if (c) c.textContent = "0 条";
    return;
  }
  // smart.trace 的真实格式(见 lib/smart.sh 的 smart_trace):
  //   "10-24 17:25:00 from>to 原因文字 score=45 t=58000 busy=40 prime=20 fps=98 psi=12"
  // 时间是两段(日期 + 时刻), 用空格隔开; 换档是 from>to;
  // 信号是 key=value 形式跟在后面。
  const items = lines.slice().reverse().map(line => {
    const m = /^(\S+\s+\S+)\s+(\S+)>(\S+)\s+(.*)$/.exec(line);
    if (!m) {
      return { ts: "", from: "", to: "", dir: "up", reason: line, sigs: [] };
    }
    const ts = m[1], from = m[2], to = m[3], rest = m[4] || "";
    // 原因文字 = 去掉所有 key=value 之后的剩余部分
    const reason = rest.replace(/\s*(score|t|busy|prime|fps|psi)=\S+/g, "").trim();
    // 提信号
    const sigs = [];
    const pick = k => {
      const mm = new RegExp("(?:^|\\s)" + k + "=(-?\\d+)").exec(rest);
      return mm ? +mm[1] : null;
    };
    const score = pick("score");
    const temp = pick("t");     // 毫摄氏度
    const busy = pick("busy");
    const fps = pick("fps");
    if (score !== null) sigs.push(["分数 " + score, score >= 62 ? "warm" : ""]);
    if (temp !== null && temp > 0) {
      const c = Math.round(temp / 1000);
      sigs.push(["温度 " + c + "°C", c >= 58 ? "hot" : c >= 50 ? "warm" : ""]);
    }
    if (busy !== null && busy >= 0) {
      sigs.push(["占用 " + busy + "%", busy >= 85 ? "warm" : ""]);
    }
    if (fps !== null && fps >= 0) {
      sigs.push(["帧率 " + fps + "%", fps < 60 ? "hot" : fps < 85 ? "warm" : ""]);
    }
    const psi = pick("psi");
    if (psi !== null && psi >= 0) {
      sigs.push(["争用 " + psi + "%", psi >= 40 ? "hot" : psi >= 20 ? "warm" : ""]);
    }
    // 方向: 从高到低算降档
    const order = { performance: 3, game_medium: 3, balanced: 2, powersave: 1, "powersave+": 0 };
    const a = order[from], b = order[to];
    const dir = (a !== undefined && b !== undefined && b < a) ? "down" : "up";
    return { ts, from, to, dir, reason: reason || "—", sigs };
  });
  el.innerHTML = items.map(it =>
    `<div class="dt-item" data-dir="${it.dir}">
      <div class="dt-top">
        <b>${esc(ZH_PROFILE[it.from] || it.from || "?")} → ${esc(ZH_PROFILE[it.to] || it.to)}</b>
        <time>${esc(it.ts)}</time>
      </div>
      <div class="dt-reason">${esc(it.reason)}</div>
      ${it.sigs.length ? '<div class="dt-signals">' + it.sigs.map(s =>
        `<span class="dt-sig${s[1] ? " " + s[1] : ""}">${esc(s[0])}</span>`).join("") + "</div>" : ""}
    </div>`).join("");
  const c = $("trace-count");
  if (c) c.textContent = items.length + " 条";
}

async function loadLoopState() {
  const out = await sh(`echo "=lp=$(cat ${CFG}/runtime/loop.state 2>/dev/null)";
echo "=cs=$(cat ${CFG}/runtime/cap.state 2>/dev/null | tr '\\n' '|')"`);
  const pick = k => { const m = new RegExp("^=" + k + "=(.*)$", "m").exec(out); return m ? m[1] : ""; };
  const loop = {};
  String(pick("lp")).split(/\s+/).forEach(tok => {
    const i = tok.indexOf("=");
    if (i > 0) loop[tok.slice(0, i)] = tok.slice(i + 1);
  });
  const cap = {};
  String(pick("cs")).split("|").forEach(tok => {
    const i = tok.indexOf("=");
    if (i > 0) cap[tok.slice(0, i)] = tok.slice(i + 1);
  });
  return { loop, cap };
}

/* v2.1 游戏调度: official=交官方让路 / module=模块接管 */
async function loadGameMode() {
  const seg = $("game-mode-seg");
  if (!seg) return;
  const m = (await sysOpt("game_mode")) || "official";
  seg.querySelectorAll("button[data-gmode]").forEach(b => b.classList.toggle("active", b.dataset.gmode === m));
  renderGameModeInfo(m);
}
function renderGameModeInfo(m) {
  const el = $("game-mode-info");
  if (!el) return;
  el.innerHTML = m === "module"
    ? row("当前", "模块调度") +
      row("保底档位", "中度游戏 (2.2/2.7/3.1 GHz)") +
      row("升性能条件", "帧率 <60% 或 CPU 占用 ≥85%") +
      row("高温处理", "≥54°C 取消保底，≥58°C 强制降档")
    : row("当前", "官方调度") +
      row("模块动作", "完全不碰 CPU，只切触控采样率") +
      row("适合", "官方 HyperBoost / 风驰已能压住帧率时");
}
async function setGameMode(m) {
  await setOpt("game_mode", m);
  $("game-mode-seg").querySelectorAll("button[data-gmode]").forEach(b => b.classList.toggle("active", b.dataset.gmode === m));
  renderGameModeInfo(m);
  vib(10);
  msg(m === "module" ? "游戏改由模块调度（20s 内生效）" : "游戏交官方调度（20s 内生效）");
}

/* v3.0 调度倾向: save=省电 / balance=均衡 / perf=性能
   语义是"给综合评分加偏置", 不是锁档位 —— 硬规则(息屏/高温/应用策略/游戏)不受影响。
   UI 形态借鉴 NovaSched 的 mode-grid: 卡片列出每个倾向的实际影响, 选中打勾。 */
const TEND_NAME = { save: "省电", balance: "均衡", perf: "性能" };
const TEND_TIP = {
  save: "更容易落到省电档，更难升到性能档",
  balance: "不偏不倚，按现场信号自动判断",
  perf: "更容易升到性能档，更难掉到省电档"
};
function markTendency(t) {
  const seg = $("tendency-seg");
  if (!seg) return;
  seg.querySelectorAll("[data-tend]").forEach(b => {
    const on = b.dataset.tend === t;
    // 用 data-state 表达选中: CSS 里 [data-state=active] 控制打勾与高亮
    b.setAttribute("data-state", on ? "active" : "idle");
    b.setAttribute("aria-pressed", on ? "true" : "false");
  });
  const st = $("tend-state");
  if (st) st.textContent = TEND_NAME[t] || "均衡";
}
async function loadTendency() {
  if (!$("tendency-seg")) return;
  const t = (await sysOpt("tendency")) || "save";
  markTendency(TEND_NAME[t] ? t : "save");
  renderTendencyInfo(TEND_NAME[t] ? t : "save");
}
function renderTendencyInfo(t) {
  // v3.1.0: 说明文字直接写在卡片的 <small> 里, 这里只同步状态位与规则行
  const r = $("rule-tendency");
  if (r) r.textContent = TEND_NAME[t] || "均衡";
  const st = $("tend-state");
  if (st) st.textContent = TEND_NAME[t] || "均衡";
}
async function setTendency(t) {
  if (!TEND_NAME[t]) return;
  await setOpt("tendency", t);
  markTendency(t);
  renderTendencyInfo(t);
  vib(10);
  msg("调度倾向改「" + TEND_NAME[t] + "」（20s 内生效）");
}

function initEvents() {
  /* dock 导航: 4 个平级 page */
  document.querySelectorAll(".dock button[data-page]").forEach(b =>
    b.addEventListener("click", () => setPage(b.dataset.page)));

  $("refresh-btn").addEventListener("click", async () => {
    await loadStatus();
    await loadDaemon();
    msg("已刷新");
  });

  /* v1.2.0 调度层节点: 重新探测 / 档位自检 */
  if ($("sched-probe-btn")) $("sched-probe-btn").addEventListener("click", () => {
    vib(10);
    loadSchedNodes();
  });
  /* v2.1 游戏调度: 官方 / 模块 */
  if ($("game-mode-seg")) $("game-mode-seg").querySelectorAll("button[data-gmode]").forEach(b =>
    b.addEventListener("click", () => setGameMode(b.dataset.gmode)));
  /* v3.0 调度倾向: 省电 / 均衡 / 性能(卡片形态) */
  if ($("tendency-seg")) $("tendency-seg").querySelectorAll("[data-tend]").forEach(b =>
    b.addEventListener("click", () => setTendency(b.dataset.tend)));
  if ($("sched-check-btn")) $("sched-check-btn").addEventListener("click", async () => {
    vib(10);
    const r = await execT(`sh ${MOD}/lib/sched.sh check 2>&1`);
    const out = $("sched-check-out");
    const txt = String(r.stdout || r.stderr || "").trim() || "(无输出)";
    out.hidden = false;
    out.textContent = txt;
    msg(/^OK/m.test(txt) ? "档位自检通过" : "自检发现问题，详见输出");
  });

  /* role=switch 的按钮(不是 checkbox) */
  bindSwitch("daemon-toggle", on => setDaemon(on));
  bindSwitch("touch-toggle", on => toggleFileValue("touch", on));
  bindSwitch("notify-toggle", on => toggleNotifyValue(on));
  bindSwitch("debug-toggle", on => toggleFileValue("debug", on));
  bindSwitch("zram-toggle", on => {
    setOpt("zram", on ? 1 : 0);
    msg("ZRAM 开关已保存 (重启挂载生效)");
  });
  /* 极致省电: 全局限制层开关。
     真正生效要等守护进程下一轮发布状态(最多 20s), 所以这里提示"已保存"
     而不是"已生效"; 游戏期间会自动失效。 */
  bindSwitch("extreme-toggle", on => {
    setOpt("extreme", on ? 1 : 0);
    msg(on ? "极致省电已开启 (20s 内生效，游戏期间自动失效)" : "极致省电已关闭 (20s 内生效)");
    loadExtremeState();
  });
  /* 液态玻璃开关: 真正关掉 WebGL 渲染, 而不是只改个 CSS 变量 */
  bindSwitch("glass-toggle", on => {
    applyGlass(on);
    msg(on ? "液态玻璃已开启" : "液态玻璃已关闭");
    return on;
  });

  $("touch-save").addEventListener("click", saveTouch);
  $("notify-test").addEventListener("click", testNotify);
  $("log-clear").addEventListener("click", () => {
    confirmDanger("清空日志", "将清空模块日志文件。确定?", async () => {
      await clearLog();
      vib(15);
    });
  });
  $("cf-cancel").addEventListener("click", closeConfirm);
  $("cf-ok").addEventListener("click", () => { const f = cfYes; closeConfirm(); f && f(); });
  /* 规则编辑器弹窗 */
  $("rule-cancel").addEventListener("click", closeRuleEditor);
  $("rule-save").addEventListener("click", saveRuleFromEditor);
  $("rule-delete").addEventListener("click", async () => {
    const pkg = ruleEditPkg;
    closeRuleEditor();
    await deletePolicyRule(pkg);
  });
  $("rule-modal").addEventListener("click", e => { if (e.target === $("rule-modal")) closeRuleEditor(); });
  $("policy-add").addEventListener("click", () => openRuleEditor(""));
  $("policy-search").addEventListener("input", e => {
    POLICY_QUERY = e.target.value || "";
    renderPolicyList();
  });
  /* 从应用库选包 */
  $("rule-pick").addEventListener("click", async () => {
    const panel = $("rule-pick-panel");
    if (!panel.hidden) { panel.hidden = true; return; }
    panel.hidden = false;
    await ensureAppLibrary();
    renderRulePickList($("rule-pick-search").value);
  });
  $("rule-pick-search").addEventListener("input", e => renderRulePickList(e.target.value));
  $("rule-pick-list").addEventListener("click", e => {
    const b = e.target.closest("[data-pick-pkg]");
    if (!b) return;
    $("rule-pkg").value = b.dataset.pickPkg;
    $("rule-pick-panel").hidden = true;
    $("rule-error").hidden = true;
  });
  $("apps-reload").addEventListener("click", () => loadApps(true));
  $("apps-search").addEventListener("input", renderAppList);
  document.querySelectorAll("#apps-tab button[data-tab]").forEach(b =>
    b.addEventListener("click", () => {
      APP_TAB = b.dataset.tab;
      document.querySelectorAll("#apps-tab button[data-tab]").forEach(x => x.classList.toggle("active", x === b));
      renderAppList();
    }));
  $("at-add").addEventListener("click", addAppTouch);
  $("touch-daily").addEventListener("change", syncCustomBox);
  $("touch-game").addEventListener("change", syncCustomBox);
  /* 外观(浅色 / 深色) */
  document.querySelectorAll("#theme-picker .theme-swatch").forEach(b =>
    b.addEventListener("click", () => setAppearance(b.dataset.theme)));
  document.querySelectorAll("#zram-editor-tabs button[data-zramtab]").forEach(b =>
    b.addEventListener("click", () => {
      zramTab = b.dataset.zramtab;
      renderZramParams();
    }));
  $("zram-save").addEventListener("click", saveZram);
  $("zram-expand").addEventListener("click", async () => {
    const box = $("zram-editor");
    if (!box.hidden) { box.hidden = true; $("zram-expand").textContent = "展开参数编辑"; return; }
    $("zram-expand").textContent = "读取中…";
    await loadZramEditor(true);
    $("zram-expand").textContent = "收起参数编辑";
  });
  $("zram-reload").addEventListener("click", async () => {
    await loadZram(true);
    await loadZramEditor(true);
    msg("已重新读取 ZRAM 配置");
  });
  $("detect-btn").addEventListener("click", async () => {
    await exec(`MODDIR=${MOD} PMK_CONFIG_DIR=${CFG} sh ${MOD}/lib/detect.sh gen`);
    msg("device.conf 已重新生成");
    await loadStatus();
  });
  $("backup-btn").addEventListener("click", async () => {
    const r = await exec(`sh ${MOD}/lib/governor.sh backup`);
    msg(r.stdout || "备份完成");
  });
  $("cfg-export").addEventListener("click", async () => {
    const r = await exec(`sh ${MOD}/lib/config.sh export`);
    msg(r.errno === 0 ? "配置已导出到 /sdcard/Download/" : "导出失败");
  });
  $("cfg-import").addEventListener("click", () => {
    confirmDanger("导入配置", "将从 /sdcard/Download/falling_config_backup.tar.gz 恢复配置并覆盖当前所有设置。确定?", async () => {
      const r = await exec(`sh ${MOD}/lib/config.sh import`);
      msg(r.errno === 0 ? "配置已导入" : "导入失败(检查备份文件是否存在)");
      await init();
    });
  });
  $("cfg-reset").addEventListener("click", () => {
    confirmDanger("恢复默认配置", "将重置所有设置为模块默认值，当前设置会丢失(可先导出备份)。确定?", async () => {
      const r = await exec(`sh ${MOD}/lib/config.sh reset`);
      msg(r.errno === 0 ? "已恢复默认配置" : "恢复失败");
      await init();
    });
  });
}

async function init() {
  initKsu();
  await loadDeviceConst();
  initEvents();
  await loadStatus();
  await loadDaemon();
  await loadSysInfo();
  await loadTemps();
  await loadTouch();
  /* 开关状态用 aria-checked(role=switch 按钮)
     一次读完 system.conf 的全部键, 只花一次 exec(旧代码要 6 次) */
  const setSw = (id, v) => { const e = $(id); if (e) e.setAttribute("aria-checked", v ? "true" : "false"); };
  const opts = await sysOpts(["notify", "daemon", "touch", "debug", "zram", "theme", "tendency", "extreme"]);
  setSw("notify-toggle", opts.notify === "1");
  setSw("daemon-toggle", opts.daemon === "1");
  setSw("touch-toggle", opts.touch === "1");
  setSw("debug-toggle", opts.debug === "1");
  setSw("zram-toggle", opts.zram === "1");
  setSw("extreme-toggle", opts.extreme === "1");
  /* 液态玻璃开关: 状态存 localStorage, 与引擎共用同一个键 */
  const glassOn = readGlassPref() === "on";
  setSw("glass-toggle", glassOn);
  applyGlass(glassOn);
  await loadAppPolicy();
  await loadAppTouch();
  /* ZRAM: 只读一次仪表数据, 编辑器 XML 等用户展开再读 */
  await loadZram();
  /* 外观 */
  applyAppearance(opts.theme || "light");
  syncCustomBox();
  $("changelog-view").textContent =
    (await exec(`cat ${MOD}/webroot/changelog.md 2>/dev/null`)).stdout || "(无更新日志)";
  // 主状态 5s 一轮; ZRAM 数据变化很慢, 拆成 30s 一轮(每轮少一次 exec)
  setInterval(async () => {
    if (document.hidden) return;
    try { await loadStatus(); } catch (e) {}
  }, 5000);
  setInterval(async () => {
    if (document.hidden) return;
    try { await loadZram(true); } catch (e) {}
  }, 30000);
}

document.addEventListener("DOMContentLoaded", init);
