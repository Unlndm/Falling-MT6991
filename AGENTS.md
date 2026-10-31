# AI 工作规则（Falling-MT6991）

改任何代码前先读：`.monkeycode/docs/REFACTOR_NOTES.md`、本文件、`README_zh.md`。

本模块已经踩过一轮坑。先复用现有层，禁止再堆一套平行实现。

## 概念（写错直接拒）

| 词 | 含义 |
| --- | --- |
| 频率档位 | `config/profiles/*.conf`：频率上限、调速器、GPU、VM |
| 调度策略 | `config/profiles/sched_*.conf`：只动 PELT/uclamp/触控 boost |
| 智能调度 | `lib/smart.sh`：按温度/负载/帧率/前台应用/屏态自动选档，用户不配置 |
| 档位编排 | `lib/apply.sh`：档位 -> 调度策略 + IO，是唯一组合入口 |
| 极致省电 | `lib/extreme.sh`：叠加在当前档位之上的**限制层**（不是新档位）；只做值变换，不写任何节点，写入者仍是原来那一个。游戏期间自动失效 |
| ZRAM 优化 | `odm/etc/oplus_mm_config.xml` bind 覆盖 `/odm/etc`（12/16/24G 分档）+ 安装时改写 nirvana/osense 系统 XML。来源 Color ZRAM(toolfor) |

**游戏 CPU 一律不管**（v9.0 起）：不切 game 场景、不写 scx、不碰 HyperBoost 服务。

游戏让路判定（v9.2）在 `bin/falling_daemon`：

```
oem_scx = official_scx_active()   # 任一簇已是 scx(官方风驰已接管)
        | game_hit "$pkg"         # 命中用户名单(触控.md 游戏包名= , 前台或 pidof 存活)
```

命中即整体让路：不跑 LaunchBoost / 不算档位，只切触控采样率。
名单命中后重置 `last_p`，让路结束后自动恢复智能选档。

游戏名单由用户在 WebUI「触控与应用」自维护，模块不内置任何游戏包名。

禁止再引入：scx 写入、HyperBoost 禁用/恢复、每游戏调校表、类别识别、帧率档感知、线程绑核、游戏预加载。

## 信号采集（v3.0 起统一走 lib/metrics.sh）

温度 / 整机忙时 / 分簇忙时 / 帧率全部由 `met_collect` 一次收齐，结果落在全局变量
`MET_TEMP / MET_BUSY / MET_CL0..2 / MET_FPS`。**新增决策信号必须加进 metrics.sh，
不要在 smart.sh 里自己读节点**——否则每轮又会多出一批 fork，也拿不到统一的采样窗口。

分簇忙时读 `/proc/stat` 的 `cpuN` 行，按 `policy*/affected_cpus` 归并（映射缓存到
`runtime/cluster.map`，不每轮重扫）。`MET_CL0/1/2` 按 policy 枚举顺序；
`SM_PRIME` = 最后一个簇（大核）；`-1` 表示无基线或计数未推进。

## 智能调度（v2.0 起，取代场景/方案/帧率守护）

**原则：调度参数一律不暴露给用户。** 用户只剩三处可配：应用策略（`apps.conf` 包名=档位）、
触控采样率（`触控.md`）、游戏调度归属（`system.conf` 的 `game_mode`）。其余由 `lib/smart.sh` 自动决定。

决策优先级（`smart_decide`，自上而下覆盖）：

1. 息屏 → `SCREEN_OFF_PROFILE`（默认 `powersave+`）
2. 温度 ≥ 58°C → 强制降档，忽略驻留时间
3. 应用策略命中且温度 < 54°C → 直接采用该档位（档位名不存在则丢弃并记错误，不写坏档）
4. 游戏且 `game_mode=module` 且温度 < 54°C → `game_medium` 保底；帧率 < 60% 或占用率 ≥ 85% 升 `performance`
5. 游戏且 `game_mode=module` 且温度 < 54°C → `game_medium` 保底；帧率 < 60% 或占用率 ≥ 85% 升 `performance`
   （接近 v3.0 的实际顺序：保底，再判低帧/满载）
6. 综合评分（base 40 + 温度修正 + 整机占用修正 + 大核占用修正 + 帧率修正）→ performance / balanced / powersave

大核占用只做**正向加分**（≥50% +4 / ≥70% +10 / ≥90% +18），**禁止改成负向扣分**。
理由：小核忙不代表不需要性能，扣分会直接把卡顿做出来。

防抖要求（改评分时必须保留）：单次只跳一档；升档越过 `SM_ENTER_PERF`、降档跌破 `SM_EXIT_PERF`；
非温度原因换档需驻留 ≥ 20s。输入全部本机节点，读不到就跳过该项，禁止因缺节点就猜测。

负载信号用 `/proc/stat` 双采样（`smart_busy`，5s 窗口），不用 `loadavg` 的 1 分钟衰减值；
没有基线（首次采样）才回退 `loadavg`。**改数据源时必须保留这个回退**，否则首轮会误判为空闲。

评分参考：PELT/uutil_est 的利用率→频率映射、uclamp 地板钳位、帧预算反馈（留 20% 余量）、
ADPF 热余量分级。**不引入**：场景文件、配置方案、帧率守护参数、用户态调速器、每游戏调校表。

## 两个易复发的实现陷阱（v3.0 修过，改代码时注意）

1. **`log_info` / `log_err` / `log_warn` 必须显式 `return 0`。**
   写成 `[ cond ] && cmd` 时条件为假会让函数返回 1，调用点的
   `write_file ... && log_info ...` 会被误判成写入失败 → `apply_profile` 返回 1 →
   bootloop 计数被误加。
2. **来源守卫用 `${VAR:-}`。** `[ -n "$_PMK69_COMMON" ]` 在调用方开了 `set -u` 时
   会直接终止被 source 的脚本（测试脚本多半开 `set -u`）。

## 守护进程存活（v3.0 起）

`service.sh` 用父循环包住 daemon：异常退出按 5/10/15/20 秒退避重启，单次存活 ≥120s
视为稳定并清零计数，连续 5 次失败才放弃并记错误日志。
**`rc=0`（收到 TERM，卸载/显式停用）不再拉起**——不要改成无条件重启，否则卸载会被反复复活。
daemon 侧有 `mkdir` 单实例锁（残留锁按 pid 是否存活自动抢占）与 `runtime/daemon.alive` 心跳。

## 温控基线格式（改之前必须读）

`runtime/thermal.base` 每行三列：`policyN <基线> <本模块上次写入值>`。

- 当前上限 == 上次写入值 → 是自己在压，**基线不动**；
- 不相等 → 别人（换档 / OEM / 内核）改了上限，基线才跟随。

这条判断是 v2.2 修的雪崩 bug：旧版只有两列、用「当前 < 基线」判断，
结果把自己上一轮的降频当成"档位下调"，5 秒一轮继续压 15%，
60°C 恒温下 25 秒把大核从 3.6G 砍到 1.0G。**不要退回两列。**

## 控制链（CPU）

只允许这一条：

1. 息屏 `SCREEN_OFF_PROFILE`
2. 游戏（`game_mode=official` 时整体让路，完全不碰 CPU；进入让路时调 `sched.sh reset` 还原出厂节点）
3. 应用策略（`apps.conf` 包名=档位）
4. 智能评分 / 游戏保底（`lib/smart.sh`）

游戏判定有迟滞：进入立即，退出需连续 3 轮（≈15s）未命中。**不要去掉迟滞**，
否则切后台、弹输入法都会让档位来回跳。
应用失败（`sys_apply` 返回非 0）统一退避 30s，禁止改成每轮重试。

`lib/apply.sh` 只做「档位 -> 调度 + IO 的组合与顺序」；调速器由 `apply_profile` 写入，
禁止在别处改 `scaling_governor`。

## 一个节点只能有一个写入者（v3.1 硬规则）

v3.1 之前有三个层抢同一批节点、互相覆盖（温控压完上限、档位下一轮又写回去，
来回抖）。现在每个节点只有一个写入者，**新增任何节点写入前先确认它没有第二个写入者**：

| 节点 | 唯一写入者 | 位置 |
| --- | --- | --- |
| `scaling_max_freq` | `cap_apply()` | `lib/loop.sh` |
| `sugov_ext/{up,down}_rate_limit_us` | `loop_apply_exec()` | `lib/loop.sh` |
| `hmbird_sched/cpuctrl_{high,low}` | `loop_apply_exec()` | `lib/loop.sh` |
| `scaling_governor` / `scaling_min_freq` | `apply_cpu()` | `lib/governor.sh` |
| PELT / uclamp / isolate / misfit | `sched_apply()` | `lib/sched.sh` |

推论（**不要违反**）：
- `lib/thermal.sh` **只出比例**（`TH_RATIO`），不写任何节点。比例由闭环层
  乘进目标上限后统一落盘。
- `lib/governor.sh` **不碰 `scaling_max_freq`**。
- `hmbird cpuctrl_high/low` 已从 `sched_*.conf` 移除，别再加回去。

## 节点可靠度分级（实机实测，别凭直觉选写入点）

依据 `docs/arch-realdevice.md`：

| 执行点 | 可靠度 | 现象 |
| --- | --- | --- |
| `/proc/hmbird_sched/*` | 最可靠 | 写进去 60 秒纹丝不动 |
| `sugov_ext/*_rate_limit_us` | 半可靠 | 能撑 50 秒，系统会间歇重置回 10，需每轮重申 |
| `scaling_max_freq` | 不可靠 | ColorOS 高频抢占（p0 在 1200M↔2400M 跳） |

所以**档位重心在 hmbird 百分比 + sugov_ext 速率**，`scaling_max_freq` 只是兜底，
且仅在追帧压力 ≥60 时才抬（平时让位给系统，不抢同一个节点）。

`sugov_ext/up_rate_limit_us` 语义 = 两次升频的最小间隔（us），越小升得越快。
实测 200000 → CPU 钉在 798000 地板；10 → 能冲 3600000。

## 让路必须"让干净"（v3.1 修）

切到「官方调度」时**不只是"不再写"**——模块之前写进 `scaling_max_freq` 的上限
还留在节点上，会压住官方风驰，等于让了一半。
让路时必须：`cap_release()`（恢复 `cpuinfo_max_freq` + 清自己的记录）+
`sched.sh reset`（调度层还原出厂）+ 让路期间不跑 `loop_tick`。
唯一例外：**≥70°C 仍要兜底降额**（`cap_emergency_throttle`），安全优先于"不干预"。

## WebUI

- 骨架 = QQ 风格：顶部大标题 + 圆角分组卡片行 + 底部 4 Tab（状态 / 调度 / 触控 / 我的）。
  状态页列出功能行（CPU / GPU / ZRAM / 温度 / 触控 / 智能调度 / 工具），点进子页；调度/触控/我的 是一级 Tab 页。
  调度页只读：显示当前决策（档位/原因/评分/温度/占用率/帧率）+ 调度层节点，**不提供任何手动选档控件**；
  唯一例外是「游戏调度」二选一（官方 / 模块），因为它是行为归属而不是参数调校。
- 外观：`data-theme` 只有 `light` / `dark` 两档（QQ 蓝主色），不再有 4 色主题与双布局。
- `index.html` 的 `id` 必须和 `app.js` 的 `$("...")` 逐字相同。改一处就搜另一处。
- 中文界面。
- 危险操作（恢复默认 / 导入配置）要二次确认。温控没有绕过开关，也没有"解锁层"这类 /proc 覆写。
- KernelSU 协议：`window.ksu.exec(cmd, '{}', cb)`。无 ksu 时页面仍要能渲染（模拟数据）。
- `system.conf` 读写：`setOpt` 必须支持「键不存在则追加」（升级保留旧配置时新增键才写得进）；
  `sysOpt` 必须兼容字符串值（theme 非数字）。
- **分层**（v3.1）：`host.js` = 宿主适配（多宿主 exec/toast、edge-to-edge、安全区、键盘）；
  `glass-liquid.{css,js}` = 液态玻璃材质；`app.js` = 业务逻辑。**不要把三者混在一起**。
- **设计 token 化**（v3.2）：颜色/间距/圆角/时长/缓动全部写在 `theme.css` 的 `:root` 里，
  组件里**不许写死值**。深色模式只覆盖 token，不重复写组件规则。
- **角色化玻璃**（v3.2）：一个 `.g` 基类 + `data-role` 决定材质
  （course/panel/accent/lens/pill/dock）。组件**不许自己写 `backdrop-filter`**，
  只声明角色。新增组件时给它选最接近的角色。
- **`.g` 必须有 `data-role`**（ui_check.py 会查）。没有角色就没有材质语义。
- **导航是 4 个平级 page**（overview/schedule/touch/settings），不是「主页+子页」。
  新增页面：加 `<section class="page" id="page-xxx">` + dock 按钮 `data-page="xxx"`，
  两边 id 必须对应（ui_check.py 会查数量与对应关系）。
- **开关用 `role=switch` 的 button**（`aria-checked`），不用 checkbox。
  用 `bindSwitch(id, onChange)` 绑定，`onChange` 返回 false 可否决。
- **原创可视化的数据源**：`runtime/loop.state`（press/level/ema）+
  `runtime/smart.state`（fps/prime/cluster/temp）。loop.state 变化慢，
  15s 拉一次，**不要**放进 5s 的主轮询里。
- **液态玻璃用 NovaSched 的 WebGL 引擎，禁止自造近似实现**（v3.3 改）：
  `glass-liquid.js` 是 NovaSched-Zen-Edition 的 `assets/liquid-glass.js` 移植
  （ZenJooo，"WebGL adapter for Kyant Backdrop's AGSL lens"，Apache-2.0）。
  一块 WebGL stage 渲染全部玻璃面，每块玻璃在自己元素里放一张
  `<canvas class="glass-surface">`，折射/色散/边缘 rim 光全在 fragment shader 里算。
  - **不许改回 CSS/SVG 滤镜方案**。旧方案每块玻璃一个 `backdrop-filter` +
    一个 SVG `feTurbulence` 位移滤镜，30+ 玻璃面时每帧重新光栅化，
    是「设置页面非常卡」的根因之一。
  - **组件不许自己写 `backdrop-filter`**（除 `.glass-flat` 降级路径外），
    只声明 `data-role`。ui_check.py 会查。
  - **不许用逐元素 `getBoundingClientRect` + 写 CSS 变量做指针高光**：
    那是 layout thrashing，触摸滚动必卡。高光由 shader 的 rim 光提供。
  - 玻璃面尺寸/位置变化靠 `renderKey` 差分判定，静止时零重绘。
  - 改引擎后必须跑 `node tools/test_glass.js`（假 WebGL context 计调用数）。
- **安全区必须用 `--safe-top` / `--safe-bottom` token**（三重 fallback：
  `env()` → 宿主 `--window-inset-*` → `0px`）。**裸写 `env(safe-area-inset-*)` 整条声明作废**。
- **玻璃材质必须有背景才能折射**：`#glass-canvas` 是脚本画的渐变壁纸，
  同时当显示背景与折射采样源，不能是纯色。
- **弹窗遮罩不用 `backdrop-filter`**：页面已有 WebGL 玻璃面，再叠一层会让
  浏览器建立 backdrop root，把已渲染的画布复制一份 → 弹窗背后出现重影，
  而且是一次全屏 blur。
- **KernelSU 里每次 `exec` 都要起一个 root shell**（实测 150~400ms）。
  WebUI 的 exec 次数要省：
  - `system.conf` 一次读进内存缓存（`readConf`/`sysOpts`），写入后失效；
  - 慢变数据（ZRAM 仪表、应用列表）加 TTL 缓存，不要每轮重取；
  - `pm list packages` 实测 1~2 秒，只能按需加载，绝不放首屏。
  进设置页的 exec 次数控制在 1~2 次。

## 真机操作纪律（v3.0.1 踩过）

- **adb 命令返回 ≠ 设备侧进程结束**。本地 `adb shell` 被中断（超时、SIGTERM、Ctrl-C）时，
  设备上的 `su` / `sh` **不会被杀**，会继续跑。v3.0.1 实测：跑采样层时撞上死循环 bug，
  adb 侧超时了，设备上却留下 **3 个各占一个满核的进程**（合计 300% CPU），
  一直烧到几分钟后才被发现 —— 期间的 loadavg 和温度数据全被污染。
- 规矩：
  1. 在真机上跑任何可能不返回的脚本，**命令必须自带 `timeout`**（`timeout 180 sh ...`），
     不要靠本地超时兜底。
  2. 跑完**必须**核对进程：`ps -A -o PID,ARGS | grep <脚本名>`，有残留立刻 `kill -9`。
  3. 跑完**必须**清 `/data/local/tmp` 下自己建的目录。
  4. 采集温度/负载这类数据前，先确认 `top` 里没有自己的残留进程。
- `tools/run_device_selftest.sh` 已内置 `timeout` + 自动清理临时目录，但**仍需人工确认一次进程**。

## Shell

### 真机 shell 是 mksh，不是 bash（v3.0.1 踩过的最贵的坑）

Android 的 `/system/bin/sh` 是 mksh/ksh 系。**ksh 把模式里的 `|` 当成"备选分隔符"**：

```
mksh:  m="a|b|c"; ${m%%|*}  ->  ""        ${m#*|}  ->  "a|b|c"   (原样不动!)
bash:  m="a|b|c"; ${m%%|*}  ->  "a"       ${m#*|}  ->  "b|c"
```

后果：用 `|` 分隔的内存索引表（`key=value|key=value|`）在真机上切不开，
凡是「取一段、去掉这一段」的循环会**既不推进也不退出 → 死循环卡死**。
v3.0.1 实测中招的有 13 处：`dev_get`（device.conf 查表）、
`met_cpu`（分簇映射，直接把守护进程卡死）、`sched_path_of` / `sched_base_of`（调度节点表）、
`thermal`（基线表）。**本地 bash 全绿，真机全废。**

规则：

- **模式里绝不能出现 `|`**。内存表分隔符统一用 `,`（键和值里都不会出现逗号）。
- 改完库函数后必须跑 `sh tools/run_device_selftest.sh`——它把整套测试搬到设备上，
  用真机的 mksh 验真。**bash 下的绿灯不代表真机绿灯。**
- 真机身份确认：`adb shell ls -l /system/bin/sh`（本机是 mksh 系 334944 字节）。
- 其余 mksh 差异本项目已规避：不用 `[[ ]]`、不用 `${v^^}`、不用数组、不用 `echo -e`、
  不用 `source`（一律 `.`）。改代码时别引入。

### 运行时文件格式必须有版本号

`config/runtime/` 下的文件跨版本保留。改过字段分隔符或结构之后，
旧文件会被新代码当成新格式解析（实机就撞上：旧 `cluster.map` 用 `|`，
新代码按 `,` 切 → 又变死循环）。

- 改任何 runtime 文件结构，**必须把 `common.sh` 的 `PMK_FMT_VER` 加 1**。
- `runtime_dir()` 会调 `runtime_fmt_check()`：版本对不上就把 runtime 里的旧**文件内容清空**
  （用 `: > file`，不用 `rm`——删除在受限环境会被拦；目录一律跳过，`daemon.lock` 由它自己的
  pid 存活判定处理）。
- `config/` 下的持久文件（`sched_backup` / `io_backup` 等）不归它管，改格式要自己写迁移。

### 其他

- 守护进程可能在 `system/bin/falling_daemon` 或 `bin/falling_daemon`。`MODDIR` 必须落到模块根（有 `lib/` 的那一层）。
- 调 `lib/*.sh` 用 `sh script.sh args`。禁止 `. script.sh args` 以为能传 `$1`。
- `touchHidlTest` 必须用 `/odm/bin` 或 `/vendor/bin` 绝对路径。
- 安装脚本禁止在 `touch_defaults` 已禁用触控之后，再用音量键把 `touch_enabled` 写回 1。
- `write_file` 走 `chown root:root` + `chmod 644`。禁止 chmod 666/777 系统节点或 `/data/powercfg.sh`。
- 新增 sysfs 节点必须是 MTK/Oplus 路径。禁止 kgsl、walt、adreno、bus_dcvs。
- README / UI 只许写代码里真实存在的节点。`lib/sched.sh` 的 `SCHED_NODES` 没有的键，禁止写进档位 conf。
- 守护进程的「前台包 / 屏态」必须是事件驱动：`logcat -b events` 的
  `wm_set_resumed_activity`（载荷含包名）与 `screen_toggled`（1/0）写进
  `config/runtime/foreground.pkg`、`screen.on`，主循环只 `read` 小文件。
  禁止退回每轮 `dumpsys`（实测 `dumpsys activity top` 单次 ~900ms，是最大开销源）。
  注意：本机型 `am_resume_activity` 不产生事件，别用它。屏态也不要用亮度节点判定
  （息屏读到的是 1 不是 0，量级不可靠）。
  退出必须 `fg_watch_stop`（TERM/EXIT trap）+ `uninstall.sh` 兜底 pkill，不留 logcat 残余。
- 循环内高频读取一律用内建 `read`，不要用 `cat` / `grep` 起子进程（实测单次 fork ~13ms）。
  `sched_target_build` 这类逐行解析不要每轮跑，只在换档或配置更新时重建。
- **热路径禁止命令替换**：`$(...)` 本身就是一次 fork，哪怕里面是内建命令。
  读单个开关用 `cfg_get KEY`（结果在 `_CFG_VAL`），读整个小文件用 `file_slurp PATH`（结果在 `_FILE_BUF`），
  需要返回值时让函数写全局变量（如 `touch_policy_code` → `TPC_CODE`、`app_profile` → `APP_PROFILE`）。
  目前 v3.0 每轮 0 个、单次切档 8 个；加功能前先数一遍自己引入了几个 fork。
- **切档链路同样禁止命令替换**：`load_profile` 用参数扩展去 CR/空白（不要 `printf|tr|sed`）、
  `field` 用内建分词（不要 `awk`）、`write_file` 用内建 `read`（不要 `$(cat)`）、
  `policy_list` 走进程内缓存、`device.conf` 用 `dev_get` 内存索引（不要 `grep`+`cut`）。
  改这些函数时先跑 `bash selftest_perf.sh`，它会数一次 `apply_profile` 的子进程数。
- 温度采样用 `thermal_max_temp`（结果在 `TH_TEMP`），zone 路径缓存 60s。
  **不要**在循环里 `cat /sys/class/thermal/*/type`：一个 zone 两次 fork，30~40 个 zone 就是每轮 60~80 次。
- 温度 zone 的匹配口径**必须与 `lib/metrics.sh` 的 `met_scan_zones` 一致**
  （`cpu-*|cpu_*|soc-*|soc_*|gpu*|mtkts*`）。实机同时存在 `soc-top*`（连字符）与
  `soc_max`（下划线），漏一个就会出现「UI 显示的温度」与「温控实际用的温度」不是一回事。

## 改代码时

1. 先读现有 `lib/*.sh` 和 `webroot/`，顺着现有函数改。
2. 一层只做一件事。频率、PELT、触控、温控分开。
3. 改 WebUI 后：每个新/旧 `id` 在 html 和 js 都能搜到；每个 `getElementById` 在 html 有对应节点。
4. 改守护后：确认 `service.sh` 启动的 `system/bin` 路径仍能 source 到 `lib/`。
5. 禁止为了「完整」补齐骁龙调度、虚构 CLI。
6. 禁止顺手大重构无关文件。
7. 用户纠正过的术语以用户为准，立刻改 UI/注释/README。

## 提交前自检

- [ ] 没有任何游戏 CPU 干预（scx / HyperBoost；名单命中时整体让路）
- [ ] 控制链仍是上面四层
- [ ] html id 与 js 一致
- [ ] daemon MODDIR 两条启动路径都能找到 `lib/`
- [ ] 没有新增 qcom 路径、没有 777、没有 source 带参
- [ ] 热路径没有新增 `$(...)`；thermal.base 仍是三列
- [ ] 新增决策信号走 `lib/metrics.sh`，不在 smart.sh 里单独读节点
- [ ] 改了切档链路就跑 `bash selftest_perf.sh`
- [ ] system.conf 新增键在旧配置上也能写入（setOpt 追加）
- [ ] **参数展开模式里没有 `|`**（mksh 会当备选分隔符 → 死循环）
- [ ] 改了 runtime 文件结构就 `PMK_FMT_VER` 加 1
- [ ] **改过 `lib/*.sh` 就跑 `sh tools/run_device_selftest.sh`**（真机 mksh 验真，不能只信 bash）
- [ ] **新增节点写入前确认没有第二个写入者**（见「一个节点只能有一个写入者」）
- [ ] `lib/thermal.sh` 没有写任何节点（只出比例）
- [ ] `lib/governor.sh` 没有写 `scaling_max_freq`
- [ ] `sched_*.conf` 里没有 `HMBIRD_CPUCTRL_*`
- [ ] 让路路径调了 `cap_release` + `sched.sh reset`，且让路期间不跑 `loop_tick`
- [ ] 极致省电是「叠加限制层」：只做值变换（`extreme_clamp_profile`），**不写任何节点**，不引入第二个写入者
- [ ] 极致省电游戏期间自动失效（`runtime/extreme.state` 由 daemon 每轮重算，命中游戏名单/进程即置 0）
- [ ] 关闭极致省电后节点还原出厂值（`loop_restore_extreme` 还原执行器节奏 + `apply_profile_non_cpu` 还原 GPU/cm/c2ps）
- [ ] 极致省电新增/调整参数只改 `config/profiles/extreme_overlay.conf`，不动 `lib/extreme.sh` 代码
- [ ] 改过 `lib/extreme.sh` 就跑 `sh selftest_extreme.sh`（45 项断言）
- [ ] `config/defaults/` 与 `config/` 一致（`diff -r` 排除 runtime/device.conf/defaults）
- [ ] 新增的 WebUI 文件在 `index.html` 里有引入；`glass-liquid.js` 引用的 id 在 HTML 里存在
- [ ] **改了 webroot 就跑 `python tools/ui_check.py`**（HTML/CSS/id/角色/page 结构）
- [ ] **改了原创可视化就跑 `node tools/test_viz.js`**（39 项断言）
- [ ] 新增组件的颜色/间距/圆角用的是 token，不是写死的值