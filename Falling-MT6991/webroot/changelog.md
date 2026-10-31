Falling-MT6991 更新日志
========================

v3.6.1 (2026-10-31)
  修正 v3.6.0 里的换档抖动，并把真机自检的环境隔离补齐。

  1) CPU 争用（PSI）权重 +20 → +12
     实机 smart.trace 显示轻载基线分约 19，回到均衡档的门槛是 39；
     +20 会让 PSI 这一个噪声信号单独跨过门槛，造成省电档与均衡档
     每 20 秒来回跳（10 分钟 13 次，两档各占一半）。
     +12 后同样的输入得 37 分，不再跨门槛；真实负载仍靠整机占用（≥55% +10）、
     大核占用（≥50% +4~18）、低帧（+30）叠加升档。
     阈值（avg10 ≥20%）与需求下限（整机或大核 ≥45%）保持不变。

  2) 修正换档原因文案
     实机日志出现过「智能档位 -> balanced (温度偏高, 降档)」，
     实际是从 powersave 升到 balanced，方向与文案相反。
     现在只有真正的降档（或原地保持）才写「温度偏高, 降档」。

  3) 真机自检隔离真实帧率节点
     selftest_smart.sh / tools/mk_testenv.py 把 /sys/kernel/fpsgo 也映射到
     测试目录。之前测试环境没隔离它，设备有动画时读到 fps 10~70，
     「低帧 +30」会把含帧率的断言打偏，导致真机自检偶发失败。

v3.6.0 (2026-10-31)
  智能调度加深一层：补上「任务在排队等 CPU」这个平均利用率看不见的信号，
  并修正两处会让决策吃到陈旧数据的小问题。

  1) 新增 CPU 争用信号（PSI）
     - lib/metrics.sh 新增 met_psi：读 /proc/pressure/cpu 的 some avg10
       （内核文档 accounting/psi.rst 的标准接口，不是厂商私有的）。
     - 只当二级判据：avg10 ≥20% 且整机或大核占用 ≥45% 才 +20 分。
       轻载下几个后台线程在小核排队就能把 PSI 顶到两位数（Kin-Daemon 实测结论），
       不加需求下限会白白抬频。
     - 节点缺失（内核未开 CONFIG_PSI）返回 -1，整个信号跳过，不影响原有决策。
     - 调度页「帧率闭环仪表」新增第 4 条：CPU 争用；决策历史也显示争用值。

  2) 大核占用分档补齐
     之前只有 ≥70% +10 / ≥90% +18，50%~69% 没有加分，与文档里写的
     ≥50% +4 不一致。现在按分档补齐：≥50 +4 / ≥70 +10 / ≥90 +18。

  3) 帧率读不到时清零连续计数
     旧逻辑在帧率无数据时保留 lowc/hic 计数，下次一有数据就可能立刻凑够
     「连续 2 轮低帧」去升档。现在读不到就清零，与「读不到就跳过」一致。

  4) 守护进程去掉一次重复帧率采样
     met_collect 内部已经采过帧率，主循环又单独调了一次 met_fps。

  5) 运行时格式版本 3 → 4
     smart.state / smart.trace 新增 psi 字段，升级时按既有规则清空一次 runtime。

v3.5.0 (2026-10-31)
  日常偏省电。用户反馈「不够省电」，这次不加新档位，而是把默认行为整体
  往省电方向挪一档，重负载仍由智能调度自动升档。

  1) 「均衡档」重标定为真正的日常省电档（不是新增档位）
     - CPU 三簇上限从接近满频降到各簇最高频的约 75%：
       2400000 / 3300000 / 3600000 → 1800000 / 2400000 / 2800000。
       三个值都取自实机频率表（docs/arch-realdevice.md），不是估计值。
     - 闭环执行器档位 EXEC_LEVEL 3 → 2（升频节奏更缓、boost 阈值更高）。
     - GPU 上限 1508000 → 988000（实机 GPU 频点），GPU boost 保持关闭。
     - cm_mgr 性能模式（CM_PERF_MODE_ENABLE）1 → 0。
     - 其余（调速器 sugov_ext、devfreq dummy、c2ps、IO 等）不变。
     - 重负载 / 追帧压力上来时，智能调度仍会升到 performance 档
       （2.4 / 3.3 / 3.73 GHz），性能档不受本次改动影响。

  2) 默认调度倾向 balance → save
     system.conf 的 tendency 默认值改为 save（省电偏置 −15）。
     息屏降档、高温强制降档、应用策略、游戏保底等硬规则不受倾向影响。

  3) 新增「出厂还原档」stock.conf，卸载不再残留低功耗值
     旧版 uninstall.sh 用 `apply balanced` 还原。均衡档一旦变省电，
     卸载后到重启前会残留 1.8/2.4/2.8 GHz + GPU 988 MHz 这类低功耗值。
     现在卸载改用 stock.conf（不限频、GPU 回 1508 MHz、cm_mgr 性能模式开），
     并显式释放模块写过的 scaling_max_freq（恢复到 cpuinfo_max_freq）。

  4) 升级迁移：选择「保留配置」也能拿到省电改动
     旧包的 config/defaults 会盖掉新包的默认，「恢复默认」会退回旧行为；
     现在保留配置时始终使用新包的 defaults。
     若 balanced.conf 仍是旧版原样（2.4/3.3/3.6 GHz），升级时替换为日常省电档，
     并把默认倾向 balance 同步为 save（用户手动选过 perf 的不动）；
     老配置缺失的 stock.conf 一并补上。用户自己改过的档位文件不会被覆盖。

v3.4.0 (2026-10-24)
  新增「极致省电」限制层。用户反馈省电档还不够省，于是加了一个
  **叠加在当前档位之上**的全局限制层（不是第六个档位）：

  - 形态：system.conf 的 `extreme` 开关 → WebUI「我的」页一键开/关；
    设置页显示的是守护进程发布的**最终生效态**（含游戏豁免），不是开关本身。
  - 力度（强限制，会牺牲响应速度，这是极致省电的应有代价）：
    - CPU 三簇上限压到实机频率表的低频点（取 <= 目标的最大真实频点，保证可写）
    - GPU 上限压到最低可用频点 + 关 GPU boost + 调速器 powersave
    - 关 cm_mgr 性能模式（`cm_perf_en=0`）+ 开 c2ps 省电模式
    - sugov_ext 升频间隔拉到很大（升得极慢）、降频间隔拉到最小（掉得极快）
    - hmbird boost 阈值拉高（很少触发 boost）
    - 调度策略一律用最省电的那套
  - 游戏豁免（产品硬规则：游戏 CPU 一律不管，游戏不做极致省电）：
    命中游戏名单 / 游戏进程存活时，守护进程每轮把限制层状态置 0，整体失效。
  - 出厂值还原：退出限制层时，执行器节点（升频节奏/boost 阈值）照备份写回，
    非 CPU 节点（GPU/cm_mgr/c2ps）照档位原值写回，不残留省电值。
  - 标定入口：`config/profiles/extreme_overlay.conf`（实机标定完只改这一个文件）。
  - 不引入第二个节点写入者：本层只做值变换，写入者仍是原来那一个
    （CPU 上限→governor、执行器节奏→loop、调度策略→apply）。

v3.3.0 (2026-10-24)
  液态玻璃换成 NovaSched 原版引擎(WebGL 镜面折射), 修「设置页面非常卡」,
  应用策略改成 NovaSched 的规则页交互。

  0) 液态玻璃: 换回 NovaSched 的 WebGL 引擎
     上一版的 CSS/SVG 滤镜方案是我自己的近似实现, 不是 NovaSched 的做法。
     现在完整移植 NovaSched-Zen-Edition 的 assets/liquid-glass.js
     (ZenJooo, "WebGL adapter for Kyant Backdrop's AGSL lens", Apache-2.0),
     即用户要求的「全部用它的」:
     - 一块 WebGL stage 渲染全部玻璃面, 每块玻璃在自己元素里放一张
       <canvas class="glass-surface">, 画的是背景的圆角 SDF 折射结果
     - 折射 + 光谱色散 + 边缘 rim 高光, 全部在 fragment shader 里算
     - 角色材质表与 NovaSched 一致: course / panel / dock / lens / pill /
       settings / accent / popup / dialog, 每个角色的折射高度、模糊、
       着色、透明度都按角色走
     - 纹理 LRU 缓存, 上限 24MB; renderKey 差分, 静止时零重绘
     - 壁纸改为程序化生成的渐变画布(与 theme.css 配色一致),
       不引入二进制资源, 同时当显示背景与折射采样源
     在它之上为本项目做的改动:
     - 去掉指针跟随高光(逐元素 getBoundingClientRect + 写 CSS 变量,
       30+ 玻璃面时是 layout thrashing, 触摸滚动必卡); 高光改由 shader
       的边缘 rim 光提供
     - 每块玻璃挂 ResizeObserver, 内容高度变化时精确重绘
     - 背景源由外部图片换成程序化渐变画布
     - 提供 setEnabled(): 用户关掉液态玻璃时彻底摘掉 canvas,
       退回 CSS 半透明, 不跑 WebGL, 不占显存
     - 引擎异常不再静默吞掉, 记录在 stats().lastError

  1) 修「设置页面非常卡」
     卡顿有三个独立原因, 全部处理:
     a) 玻璃层: 旧方案每块玻璃一个 backdrop-filter + 一个 SVG
        feTurbulence 位移滤镜, 30+ 块玻璃同时存在时每帧都要重新光栅化。
        换成 WebGL 后是一次 GPU 绘制, 静止时零重绘。
     b) exec 风暴: KernelSU 里每次 exec 都要起一个 root shell
        (实测 150~400ms)。旧代码进设置页会发起 8 次 exec:
        loadLog + loadAppearance + loadZram + loadZramEditor(内含 4 次 sh)
        + sysOpt×5。现在:
        - system.conf 一次读进内存缓存, 写入后失效
        - ZRAM 仪表与探测合并成一次 exec, 结果缓存 30 秒
        - ZRAM 参数编辑器默认折叠, 用户点「展开参数编辑」才读 XML
        - 切页不再重复加载 ZRAM 编辑器
        - 应用列表 pm list packages(实测 1~2 秒)改为按需加载,
          不在首屏跑
        进设置页的 exec 次数从 8 次降到 1~2 次。
     c) apps.conf 被读两次(应用策略 + 专属采样率), 合并成一次。

  2) 应用策略: 移植 NovaSched 的规则页交互
     - 规则行改成玻璃卡(data-role=course + 彩色索引), 每行一个色
     - 应用名 + 首字母头像(颜色由名字散列, 同一个 App 永远同色);
       包名对普通用户不友好, 优先走宿主元数据桥 getPackagesInfo,
       拿不到就退回包名末段
     - 左滑露出删除按钮(用 pointer 事件自己跟踪位移, 不与页面滚动打架)
     - 点规则行进编辑弹窗: 包名 + 档位 chips + 删除, 不再弹原生 confirm
     - 新建策略时可「从应用库选择」, 不必手打包名
     - 搜索框同时匹配包名与应用名
     - 渲染 key 差分: 内容没变就不重建 DOM, 轮询时规则列表不会闪
     - 专属采样率列表同步改成同样的玻璃规则行

  3) 修 UI 缺陷
     - dock 四个页签图标不渲染: glass-liquid.css 里的 `.g > *` 规则
       覆盖了 .dock-indicator 的 position:absolute, 指示器变成 grid item
       把按钮挤出格子。改为依赖 .g 自带的 isolation:isolate, 让负
       z-index 的画布自然落在内容之下
     - 概览 Hero 卡「整机占用」显示成 loadavg 原始串
       (1/5/15 0.42 0.38 0.35), 改为显示 smart.state 的 busy 百分比
     - 弹窗遮罩去掉 backdrop-filter: 页面已有 WebGL 玻璃面, 再叠一层
       会让浏览器建立 backdrop root, 把已渲染的画布复制一份 -> 弹窗
       背后出现重影, 而且是一次全屏 blur
     - 设置页「展开参数编辑」按钮, ZRAM XML 按需读取
     - 修复预览页生成器: 版本号写死导致 CSS/JS 内联失效,
       预览页一直是外链(双击打开白屏), 现改为正则匹配

  4) 新增测试
     - tools/test_glass.js: 玻璃引擎回归测试(用假 WebGL context 计调用数)
       断言首帧只画可见页面的面 / 静止零重绘 / 切页旧面释放新面绘制 /
       关闭玻璃后零绘制 / 纹理缓存有字节上限
     - tools/ui_check.py 改为验证 WebGL 架构: 检查 shader 的 SDF 圆角 +
       折射 + 色散实现齐全, 且非降级路径不得出现 backdrop-filter

v3.2.0 (2026-10-24)
  WebUI 全量重构: 设计体系整体学习 NovaSched-Zen-Edition, 在其上加入
  调度模块独有的原创可视化。

  0) 设计体系重建: 从「QQ 风格 + 磁贴」改为「NovaSched 风格 + 角色化玻璃」
     学到的:
     - token 化: 颜色/间距/圆角/时长/缓动全部是 token, 组件不写死值
       (新增 webroot/theme.css, 58 个 token)
     - 角色化玻璃: 一个 .g 基类 + data-role 决定材质
       (course=内容卡 / panel=面板 / accent=强调 / lens=dock指示器 /
        pill=小胶囊 / dock=底栏), 组件不自己写 backdrop-filter
     - 页面转场: 4 个平级 page, 切换时双向滑动(旧页 -12% / 新页 +18%),
       滚动位置不归零时退化为淡入; 每页保留自己的滚动位置
     - 胶囊 dock: 指示器用 --tab-index 平移, active 态用 aria-current
     - Hero 卡片: 大字档位 + 白话说明 + 3 格关键指标
     - 分区标题带状态: section-divider = 标题 + 细线 + 右侧实时值
     - mode-grid 卡片: 图标 + 标题 + 白话说明 + 打勾(调度倾向改成 3 张卡)
     - 设置页: 大标题 + settings-group + setting-row + role=switch 开关
     - 语义化触感: select/toggle/tick/success/failure/warning 六种节奏,
       同语义最小间隔限频(借鉴 NovaSched 的 haptics.js)
     - prefers-reduced-motion 全局降级
     明确不抄: 12 色配色板、壁纸系统、WebGL 液态玻璃(598 行 + 7 canvas +
       GLSL 折射, Android WebView 上是实打实的显存与兼容风险)

  1) 原创可视化 1: 帧率闭环仪表
     NovaSched 的 engine-meter 是「一条静态进度条」, 表达单一度量。
     调度闭环是多维的, 所以做成「压力环 + 三段条 + 档位刻度」:
     - 压力环: SVG 描边, dashoffset 表示压力, 颜色随压力冷->暖->热
     - 三段条: 帧率达标率 / 大核占用 / 温控降额, 各自独立配色
     - 档位刻度: 5 格, 达成格填充 + 当前格高亮(执行器 L0~L4)
     数据源: runtime/loop.state 的 press/level/ema + smart.state 的
     fps/prime。loop.state 变化慢, 15s 拉一次, 不拖慢 5s 的主轮询。

  2) 原创可视化 2: 分簇热力
     整机占用看不出瓶颈在哪: 小核吃满+大核空转 与 三簇各半 是两回事。
     三条并列的条形一眼看出谁在忙, 颜色同样按 70/90 阈值切换。
     簇数不是固定 3 个: 本机只有两簇时自动重新命名(小核/中核 -> 中核/大核)。

  3) 原创可视化 3: 决策链时间轴
     「为什么又降档了」是用户真正想看的东西, 不是一行行原始日志。
     把 smart.trace 解析成时间轴: 换档方向(升/降用颜色区分) + 原因文字
     + 当时的信号做成小标签(分数/温度/占用/帧率, 超阈值自动标 hot/warm)。
     解析按 smart.sh 的真实写入格式: "10-24 17:25:00 from>to 原因 score= t= busy= prime= fps="

  4) 新增: 液态玻璃开关 + 降级说明
     设置页可关玻璃(存 localStorage), 关掉后保留模糊、去掉折射与色散。
     不支持 backdrop-filter 时自动降级并如实说明。

  5) 修掉一个真实缺陷
     压力环画的是「帧率+大核合成」的参考压力, 但数字显示 "--" ——
     弧长与读数不一致, 用户会困惑。现在数字与弧长用同一个值。
     (由 tools/test_viz.js 的断言抓到)

  6) 测试
     新增 tools/ui_check.py: HTML 标签闭合/嵌套、CSS 括号与声明、
     变量引用与定义、类名双向匹配、id 引用一致性、page/dock 数量匹配、
     SVG 滤镜完整性、原创组件在位、玻璃角色完整性。
     新增 tools/test_viz.js: 39 项断言覆盖三个原创可视化的输出
     (压力配色分档、环长计算、无数据时的合成压力、簇数自适应、
      毫摄氏度转摄氏度、信号标签分级、倒序)。
     新增 tools/make_preview.py: 生成自包含预览页, 双击可在浏览器看到
     真实渲染(本机沙箱会杀掉浏览器进程, 无法自动截图, 预览页替代)。

v3.1.0 (2026-10-24)
  调度架构重写 + 液态玻璃 UI。
  架构改动不是拍脑袋, 全部来自实机(Node: PLC110 / MT6991 / Android 17)的三组
  受控实验数据, 见 docs/arch-realdevice.md。

  0) 实机实验: 三类节点的"存活能力"差得很远
     - scaling_max_freq        : 系统高频抢占(p0 在 1200M<->2400M 跳),
                                  写上去几秒内就被改回去 —— 不可靠
     - sugov_ext/*_rate_limit_us: 能撑 50 秒, 但系统会间歇重置回 10,
                                  需要守护每轮重申 —— 半可靠, 但效果极强
                                  (实测 200000 -> CPU 被钉在 798000 地板;
                                   10 -> 能冲到 3600000)
     - /proc/hmbird_sched/*    : 写进去 60 秒纹丝不动 —— 最可靠
     结论: 档位重心必须按可靠度重排, 不能继续把宝押在 scaling_max_freq 上。

  1) 新增 lib/loop.sh: 帧率闭环 + CPU 上限决策层
     这是本次架构的核心。闭环层做两件事:
     a) 帧率闭环: 用帧率达标率(EMA) + 大核占用 + 温度算"追帧压力"(0..100),
        映射到执行器档位 level 0..4, 落到 hmbird 阈值与 sugov_ext 速率上。
        帧率富余就收紧(省电), 帧率不足就放开(追帧) —— 不再是死写上限。
        带 EMA 平滑、滞回(连续 2 轮一致才换)、最小间隔 20s、每轮只跳一档。
     b) 上限决策: scaling_max_freq 的**唯一写入者**。档位目标上限 ∩ 温控降额,
        并做让位判定 —— 系统主动压低且追帧压力不高时接受系统的值, 不抢同一个节点。
        只有追帧压力 >= 60 时才把上限抬回目标(这是"追帧"才做的事, 不是常态)。
     执行器档位表(实测调出来的, 不是猜的):
        level 0..4 -> up_rate(us):   3000 1500  700  300   10
                    -> down_rate(us):   10   10  100 1000 10000
                    -> cpuctrl_high:    80   70   60   52   45
                    -> cpuctrl_low:     60   52   45   40   35

  2) 硬规则: 一个节点只能有一个写入者
     改之前有三个层抢同一批节点, 互相覆盖:
       - governor.sh 写 scaling_max_freq / sugov_ext 速率
       - thermal.sh  自己写 scaling_max_freq(温控降频)
       - sched.sh    写 hmbird cpuctrl_high/low
     现在:
       scaling_max_freq  -> 只归 cap_apply(loop.sh)
       sugov_ext 速率    -> 只归 loop_apply_exec(loop.sh)
       hmbird cpuctrl_*  -> 只归 loop_apply_exec(loop.sh), 从 sched_*.conf 移除
       governor.sh       -> 只写调速器与最低频率, 不碰上限
       thermal.sh        -> 只出降额比例(TH_RATIO), 不自己写节点
     以后新增任何节点写入, 先确认它没有第二个写入者。

  3) 修复: 让路是"半让路"(Kin-Daemon 的洞见)
     之前切到"官方调度"时只是"不再写", 但模块之前写的 scaling_max_freq
     还留在节点上, 会压住官方风驰 —— 等于让了一半。
     现在让路时调 cap_release: 把各簇上限恢复到 cpuinfo_max_freq,
     并清掉自己的记录。调度层同时还原出厂。
     (Kin-Daemon 的 CODE_WIKI 明确点了这个坑。)

  4) 档位配置语义变了
     档位文件里的 UP_RATE / DOWN_RATE 死键删除, 换成 EXEC_LEVEL:
     该档允许的闭环执行器最高档位(0 最保守 ~ 4 最激进)。
     MAXFREQ 的含义也变了: 从"写死的上限"变成"目标上限",
     到底抬不抬由闭环层按追帧压力决定。

  5) 新增 webroot/host.js: 宿主适配层
     之前只认 window.ksu。现在统一多宿主 exec/toast 归一化, 并处理:
     edge-to-edge(WindowInsetsController + visualViewport)、安全区三重 fallback、
     键盘让位、软键盘避让。
     顺手修了个真 bug: 之前的 .appbar 顶部完全没管安全区 ——
     全面屏上标题会被状态栏遮住。

  6) 新增 webroot/glass-liquid.css + glass-liquid.js: 液态玻璃材质层
     实现路径与 NovaSched 不同: 它用 598 行 WebGL(7 canvas 合成 + 手写 GLSL
     圆角 SDF 折射 + 光谱色散), 调度模块的 WebUI 是"打开看一眼状态",
     不是欣赏折射; Android WebView 上那套的兼容性与显存开销是实打实的风险。
     本模块改用 SVG feTurbulence + feDisplacementMap 折射 + backdrop-filter,
     视觉等价、开销低、零 WebGL。
     含: 动态渐变壁纸层(玻璃必须有背景才能折射)、边缘色散、
     指针跟随高光、浅/深色两套材质变量、不支持 backdrop-filter 时降级。

  7) 调度倾向从分段控件改成卡片网格
     学自 NovaSched 的 mode-grid: 图标 + 标题 + 白话说明 + 生效打勾。
     原来的分段控件只能显示"省电"两个字, 说不清三者差别。

  8) 测试
     新增 selftest_loop.sh(闭环压力映射、执行器档位、让位判定、让路释放,
     温控层只出比例不写节点, 共 27 项)。
     selftest_thermal.sh 重写为新架构语义(14 项)。
     PMK_FMT_VER 升到 3(新增 cap.base / cap.execmax / loop.state 等运行时文件)。
     本地六套 128 项断言全过。
     仍未装到真机跑完整模块(只跑了采样层与测试套件)。

v3.0.1 (2026-10-24)
  第一次上真机(一加 Ace 5 至尊版 / PLC110 / MT6991 / Android 17 / KernelSU)抓出来的。
  这一版修的是"在真机上根本跑不起来"的问题, 外加一个新功能。

  0) 致命: mksh 的 ${var%%|*} 不是 bash 的意思
     Android 的 /system/bin/sh 是 mksh/ksh 系。ksh 把模式里的 | 当成"备选分隔符",
     于是 ${m%%|*} 返回空串、${m#*|} 原样不动。
     本模块有一批内存索引表用 | 分隔(key=value|key=value|), 在真机上的表现是:
       - met_cpu 的分簇循环切不开 policy, 循环既不推进也不退出 -> 守护进程死循环卡死
       - dev_get 查 device.conf 永远查不到 -> 频率表白名单校验全失效
       - sched_path_of / sched_base_of 同理 -> 调度档位的键一个都匹配不上
       - thermal 的基线表读取失真 -> 温控行为错乱
     本地一直是 bash 跑测试, 全部通过, 这个问题在本地永远测不出来。
     改法: 所有内存表分隔符从 | 换成 ,(键和值里都不可能出现逗号),
     受影响 13 处, 分布在 common.sh / metrics.sh / sched.sh / thermal.sh。
     以后在 mksh 上写模式, 模式里绝不能出现 |。

  1) 运行时文件加格式版本号(PMK_FMT_VER)
     runtime/ 里的文件是跨版本保留的。改过字段分隔符之后, 旧文件会被新代码
     当成新格式解析 —— 实机就撞上了: 旧的 cluster.map 用 | 分隔, 新代码按逗号切,
     pol 整个串没切开, 又变成死循环。
     现在 runtime/.fmt 存格式版本, 对不上就把 runtime 里的旧文件内容清空重来
     (用清空不用删除: 删除在受限环境会被拦, 而且 daemon.lock 是目录不能删)。
     以后改任何 runtime 文件结构, 必须把 PMK_FMT_VER 加 1。

  2) 新增: 调度倾向(省电 / 均衡 / 性能)
     之前调度档位完全由守护进程决定, 用户一个都改不了。现在给一个不影响
     自动升降档的"倾向"开关: 只给综合评分加一个固定偏置(-15 / 0 / +15),
     不锁档位。硬规则(息屏降档 / 高温强制降档 / 应用策略直通 / 游戏保底)
     一律不受倾向影响 —— 这四条在评分之前就返回了。
     位置: WebUI 智能调度页顶部的「调度倾向」分段控件, 写 config/system.conf
     的 tendency 键, 守护 20 秒内生效(与 game_mode 同节奏)。

  3) 修帧率解析的两处缺陷(实机 od -c 验证过列结构)
     fpsgo_status 的表头里 targetFPS 和 FPS_margin 之间是空格不是 tab,
     数据行第 5 列经常是空的。原来的读法在某些行会把 FPS_margin 当成目标帧率。
     另外两处修正:
       - 达标率可能算出 110%(当前 33 / 目标 30), 现在封顶 100
       - 只让"目标帧率 >= 45"的行参与判定。30fps 类的老应用掉到 20fps 时
         达标率也只有 66%, 但那不是 CPU 性能不够(给它 120Hz 也一样),
         放进来会让模块误判成"帧率撑不住"去升性能, 白白拉高频率。

  4) 温控与采样层的温度口径统一
     thermal.sh 只认 cpu-* 和 soc-*, 漏了 GPU(gpu0/gpu1) 和 soc_max(下划线),
     于是 UI 显示的温度和温控实际用的温度不是一回事。现在两边口径一致。

  5) 新增 tools/run_device_selftest.sh
     把整套测试搬到设备上跑, 用真机的 mksh 验真。以后改完库函数,
     跑一次这个脚本就知道真机行为对不对 —— bash 下的绿灯不代表真机绿灯。
     配套 tools/probe_device.sh(只读实机探测) 已经在用。

  6) WebUI: 学习 NovaSched-Zen-Edition 后的一批改进
     完整笔记见仓库 docs/ui-review-novasched.md。这次落地的是低风险项:
     - 安全区补齐: 原来只有底部用了裸 env(safe-area-inset-bottom), 顶部完全没管,
       全面屏上标题会被状态栏遮住。现在统一走 --safe-* token, 三重 fallback
       (env() -> 宿主自报的 --window-inset-* -> 0px), 只用 env() 的话在不支持的
       宿主上整条声明会作废。.appbar / .sub-hd / .tabbar / .subpage 全部接上。
     - 动效 token 化: 新增 --ease/--ease-out/--ease-swift/--ease-soft 与
       --dur-fast/mid/slow/slide, 以后整体调快慢只改这八个变量。
     - 新增 webroot/host.js: 宿主适配独立成层 —— 多宿主探测、edge-to-edge、
       visualViewport 跟随、软键盘顶起时内容让位; 并把命令执行归一化,
       顺带兼容 Magisk / APatch / MMRL(原来只认 KernelSU)。
       app.js 优先走 FallingHost.exec, host.js 没加载上时退回原 window.ksu.exec,
       KernelSU 环境下行为完全不变。
     - 「调度倾向」由分段控件改成卡片(形态借鉴 NovaSched 的 mode-grid):
       图标 + 一句白话说明 + 生效打勾。分段控件只能显示「省电」两个字,
       卡片直接写清「更容易落到省电档, 更难升到性能档」, 不用翻文档。

  实机观测(供后续调阈值参考):
     - 拓扑 policy0=CPU0-3 / policy4=CPU4-6 / policy7=CPU7, 与代码假设一致
     - 调速器 sugov_ext; hmbird_sched 节点全部存在
     - scaling_max_freq 是 ColorOS 自己在管的高频振荡节点(实测 p0 在
       1200000~2400000、p7 在 1400000~3600000 之间反复跳), 且已排除
       AppOpt/CZero/TA_utl/violet_box 等其他模块干预 cpufreq。
       档位写死的频率上限在这台机上会被系统覆盖, 真正稳的是调速器 +
       sugov_ext 的 up/down_rate_limit_us + hmbird 的百分比参数。
     - 待机温度 44~50°C; 刷短视频(抖音占 89% CPU)+充电 52~55°C。
       max 口径偶有单 zone 尖峰冲到 68.9°C, 用 max 判定降频可能偏保守。
       55/58°C 阈值在日常高负载下已到边缘, 建议小幅上调, 不必大改。
     - 实测分簇数据印证了设计意图: 刷抖音时整机占用 42%、小核 55% 而
       大核只有 10% —— 正是"大核吃满才加权"要防的那种场景, 不该升性能档。
     - Android 17 / SDK 37(此前按 15/16 写的)

  验证: 真机 mksh 上 selftest_smart 19 组全过; 本地 bash 下 selftest_smart 19 组、
  selftest_sched 30 项、selftest_io 4 组、selftest_thermal 7 组、selftest_config 8 项全过。

v3.0.0 (2026-10-24)
  这一版是结构性重写, 不是加参数。四件事: 决策看得见分簇、失败能自愈、切档不再卡、配置不再有死键。
  1) 新增采样层 lib/metrics.sh
     旧版每次决策要起 6 个命令替换(温度/负载/占用率/核数/帧率/温度修正)外加一次 awk 读帧率。
     现在一次 met_collect 收全部信号, 全内建 read, 稳定状态下每 5 秒 0 个子进程。
     同时补齐了「分簇占用」: 读 /proc/stat 的 cpuN 行, 按 policy 的 affected_cpus 归并成
     小核 / 中核 / 大核三档忙时。这是本次新增的唯一信号, 来源是标准内核接口。
  2) 决策加入分簇判断
     整机占用 45% 可能是「小核全满、大核全闲」(瓶颈在迁移/并行度, 提频收益小),
     也可能是三簇各 45%(真需要频率)。只看整机会把前者误判成后者。
     现在大核 ≥70% 加 10 分、≥90% 再加 8 分。只做正向信号, 不做负向扣分 ——
     小核忙不等于不需要性能, 扣分会直接变成卡顿。
  3) 新增决策遥测 runtime/smart.trace 与 runtime/smart.stats
     每次换档记一行: 时间 原档>新档 原因 分数 温度 整机占用 大核占用 帧率, 环形保留 240 条;
     同时累计各档位驻留秒数。调度页新增「决策历史」「分簇占用」「运行状态」三块,
     想看「为什么又降档了」不用再翻 logcat。
  4) 切档链路去 fork
     load_profile 不再每行 printf|tr|sed, 改参数扩展; field 不再每次 awk;
     write_file 的读写不再 $(cat); policy_list 缓存到进程内; device.conf 一次读入做字符串索引;
     解锁 cpufreq 前先探一个节点, 已经是 root:root 644 就整段跳过(原来每次切档 18 次 chown/chmod);
     日志轮转的 stat 从每条一次改成每 50 条一次; 逐节点写入的明细日志降级为 debug。
     实测(假 sysfs, 同档位配置): 一次切档从原先上百次子进程降到 8 次(首次) / 7 次(重申)。
  5) 守护进程可靠性与成本
     service.sh 从「& 起一个就完事」改成父循环监控: 异常退出按 5/10/15/20 秒退避重启,
     单次存活超过 2 分钟视为稳定并清零计数, 连续 5 次失败才放弃并记错误日志;
     正常退出(rc=0, 收到 TERM)不再拉起, 卸载不会被反复复活。
     daemon 增加 mkdir 单实例锁(残留锁按 pid 是否存活自动抢占) 与 runtime/daemon.alive 心跳,
     调度页可直接看到守护是否还活着、跑了多久、重启过几次。
     runtime_dir 目录存在时不再 mkdir —— 这个函数每次决策调 3~4 次。
  6) 清理
     删掉 5 个频率档位里遗留的 [FPS] 整段(共 30 个键)与 load_profile 的解析分支。
     帧率守护在 v2.0 就删了, 这些键从此没有任何代码读取, 留着只会让人以为可调。
     删掉智能评分里对 loadavg 的回退分支: 它只在开机第一次决策(还没有采样基线)时生效,
     代价是每次决策多读一个文件, 收益是一个 5 秒周期的粗略修正。
  7) 修掉两个真 bug
     log_info/log_err/log_warn 写成 `[ cond ] && cmd` 时, 条件为假会让函数返回 1;
     调用点的 `write_file ... && log_info ...` 于是被误判成写失败, apply_profile 返回 1,
     bootloop 计数会被误加。现在三个函数显式 return 0。
     common.sh 的来源守卫用了未定义的 $_PMK69_COMMON, 调用方开 set -u 时直接终止脚本;
     改成 ${_PMK69_COMMON:-}。
  「恢复默认配置」之前只清 smart.state / smart.count / profile.applied, 没清 v3.0 新增的
  遥测文件, 于是重置完调度页的决策历史还显示旧配置下的换档原因, 排查时会被误导。
  现在 smart.trace / smart.stats / cluster.map 一并清掉; daemon.restarts 故意保留 ——
  那是守护健康度的证据, 不该被"恢复默认"抹掉。新增 selftest_config 覆盖这 8 项断言。
  验证: selftest_smart(15 组, 含分簇/遥测/坏档位/驻留)、selftest_io、selftest_thermal、
  selftest_sched、selftest_config 全部通过; 新增 selftest_perf 做切档子进程计数。仍未实机验证。

v2.3.0 (2026-10-24)
  这一版只做减法: 把空实现、假开关、复制来的垃圾参数清掉。
  删掉「系统解锁层」整层。它的 /proc/ppb 与 /sys/kernel/thermal/gpt 节点值一直是空的
  （注释自己写着"写值未实机确认"），所谓"立即应用解锁"按钮什么都不做；
  真正生效的只有两个从别处搬来的 powerhal XML, 而且要重启才 bind, 界面却说立即生效。
  连带删除: lib/unlock.sh、两个 XML、post-fs-data 挂载段、system.conf 的 unlock 键、
  安装时的选项、我的页面板（含"立即应用解锁"按钮）。
  删掉温控绕过的最后一截: UI 在 v2.0 就拿掉了, 但 get/set_thermal_state、service.sh 的
  disable 分支、WebUI 顶栏读 thermal_state 的芯片都还在——芯片永远显示"温控 正常",
  因为没人再写那个文件。现在顶栏直接显示真实降频比例（来自 sched.state）。
  删掉死代码: get/set_current_profile（v2.0 后无调用者）、touch_config_save_md5 空壳、
  config.sh 里 v1.x 的遗留文件名（touch_conf_md5/fps_state/scene 等）。
  调度档位里的垃圾参数:
    - CFS_UCLAMP_MAX=1024 四个档都写 —— 1024 就是内核默认值, 等于没写;
      而且 uclamp_max 是"runqueue 里谁大听谁的", 本来就不能当频率天花板用（天花板是 scaling_max_freq）
    - HMBIRD_HEARTBEAT / HEARTBEAT_EN / WATCHDOG：hmbird 内部心跳与看门狗, 不是调优项,
      关掉看门狗还有风险
    - HMBIRD_SCX_TICK：不用 scx, 影子 tick 无意义
    - game 档的 SLIM_WALT_POLICY / SLIM_FPS：slim_walt_ctrl=0(父开关关着), 写子参数纯噪声
    - game 档的 TOUCH_BOOST_TA/FG=0：游戏里关掉 top-app 触摸升频, 和买性能档的初衷相反
  以上参数删掉后由差量还原机制在下次切档时恢复成出厂值, 不会留着上一次的数字。
  新增 tools/probe_device.sh：只读的设备探测脚本, 一次抓全 cpufreq / hmbird / 温控 / fpsgo /
  IO / 调度 sysctl, 用来决定 v2.4 该动哪些真实存在的节点。

v2.2.0 (2026-10-24)
  修掉一个会直接砍帧率的温控 bug。旧版降频基线只有一个字段，判断"档位下调了，基线要跟着降"
  用的是"当前上限 < 基线"。可是上一轮自己刚把上限压下去，这一轮读到的当前值当然更小，
  于是每 5 秒再压 15%。实测复现：60°C 恒定，上限 3.6G → 3.0 → 2.5 → 2.0 → 1.5 → 1.0 GHz，
  25 秒后大核已经在地板，温度却还在 60 度。现在基线文件多记一个"本模块上次写入的值"：
  当前值等于它，说明是自己在压，基线不动；不等于，才是别人换的档，基线才跟随。
  顺手修 IO 备份：旧版用 `cat scheduler | tr -d '[]'` 取值，节点内容是
  "mq-deadline [kyber] bfq none"，去掉方括号后整串列表都被当成原值存了下来，
  回日常时把这串写回单值节点，内核拒收 —— 也就是说"还原"从来没真正生效过。
  现在只取方括号里那个当前生效的名字；老备份（字段数不对）归档成 io_backup.old 后
  按当前值重新记录，不再把错基线往下传。
  守护进程每轮的子进程数从 60~80 降到 0~2：
    - 温度采样改内建 read，zone 路径缓存 60 秒（旧版每个 zone 两次 cat，30~40 个 zone 就是 60~80 次）
    - 降频基线表读进内存做字符串索引，不再每轮 grep|cut 每个 policy
    - 可用频率用 read 整行 + 词分割取 ≤目标的最大值，不再 cat|tr|awk
    - 触控配置变更检测从 md5sum|cut 改成内建读全文比对；专属采样率、游戏名单、状态文件全部去掉子进程
    - 应用策略查表、开关判断（新增 cfg_get）都改成内建 read
  让路（官方调度）期间不再主动压频率上限，免得和官方风驰抢同一个节点；但 ≥70°C 仍然兜底压频。
  控制链快照文件内容不变就不重写（让路期间原来每 5 秒写一次同样的内容）。

v2.1.0 (2026-10-24)
  游戏调度可以二选一了：调度页新增「游戏调度」，官方 / 模块。
    官方调度（默认）= 保持 v2.0 的做法，游戏期间整体让路，不碰 CPU，只切触控采样率。
    模块调度 = 模块接管：game_medium 保底（2.2/2.7/3.1 GHz，升频快、上限低于性能档），
      帧率低于 60% 或 CPU 占用率 ≥85% 才升 performance；温度 ≥54°C 取消保底，≥58°C 照旧强制降档。
    切到官方让路的那一刻会把调度层节点还原成出厂（sched.sh reset），
    避免模块写的 PELT / hmbird 参数和官方风驰叠在一起。
  负载信号换成实测占用率：/proc/stat 首行两次采样算 5 秒窗口忙时占比，替代 loadavg。
    loadavg 是 1 分钟指数衰减，开游戏后二三十秒才爬上来，5 秒轮询几乎看不出变化。
    没有基线（首次采样）时仍回退 loadavg，两条都读不到就不加不减。
  游戏判定加迟滞：进入立刻，退出要连续 15 秒未命中（前台没它、进程也没了），
    切后台回消息不会再让档位来回跳。
  应用策略容错：apps.conf 里的档位名不存在（拼错或被删档）时直接忽略并记错误，
    不再拿坏名字去写；sys_apply 失败统一退避 30 秒，不再每 5 秒重试刷日志。
  息屏轮询从 5 秒放宽到 15 秒，后台没有前台应用可跟，亮屏仍是 5 秒。
  修掉一个 v2.0 的 bug：调度页的节点探测函数在重构时丢了，点开「调度」会抛异常，
    节点卡永远是「点开本页自动探测…」。现已补回，会列出可用节点数、本机缺失的节点名单。
  调度页的「当前决策」新增 CPU 占用率(5s) 一行；档位自检、重新探测按钮不变。
  升级保留配置时，安装脚本会给老 system.conf 补上 game_mode=official。

v2.0.0 (2026-10-24)
  这一版把「需要你自己调」的东西全删了，改由模块自己算。
  删掉：场景中心（日常/游戏/省电/息屏四套组合）、配置方案（均衡/性能/省电三张卡）、
  状态页的一键场景按钮、帧率守护（连同阈值面板）、温控绕过开关、实验室用户态调速器、
  对外 powercfg 接口。config/scenes、config/schemes、config/fps.conf 一并删除；
  升级选"保留配置"时安装脚本会清掉这些遗留，不会留下看着能用其实没用的旧文件。
  新增 lib/smart.sh 智能调度：每 5 秒按温度、负载、帧率、前台应用、屏态打一次分，
  分数映射到省电 / 均衡 / 性能三档，再交给 lib/apply.sh 展开成频率档位 + 调度策略 + IO。
  决策优先级：息屏 → 极限省电；温度 ≥58°C 强制降档（不看防抖）；apps.conf 里指定的档位
  在温度 <54°C 时优先；其余走评分。防抖做在三处：一次只跳一档、升档要越过 62 分降档要
  跌破 54 分（省电侧 23/39）、非温度原因的换档至少间隔 20 秒。
  温度 ≥55°C 时内核温控再按比例压频率上限，和智能降档是两层，不互相打架。
  评分思路参考了 PELT/util_est 的利用率→频率映射、uclamp 地板钳位、帧预算留 20% 余量、
  ADPF 热余量分级；但只用本机真实存在的节点，读不到的项直接跳过，不猜不捏造。
  WebUI：调度页变成只读的，显示当前档位、决策原因、综合评分、温度/负载/帧率，
  下面接本机支持的调度节点清单；没有任何选档控件。状态页磁贴显示当前档位和决策原因。
  保留可配的只剩两处：应用策略（给单个 App 指定档位）和触控采样率（含游戏包名单）。

v1.2.0 (2026-10-24)
  调度层重做写入逻辑，先说修掉的 bug：
  sched_daily.conf 有 8 个键名写错（PARC_HIGH / PARC_LOW / MISFIT / C7TL / CPUCTRL_HIGH /
  CPUCTRL_LOW / ISOLATE / SLIM_WALT 少了 HMBIRD_ 前缀或名字对不上），节点表里查不到就
  静默跳过，所以「日常高负载自适应」这一档实际只写进了 3 个键，并行救援、misfit、CPU7
  阈值从来没生效过。现在改成节点表里的正式键名。
  新增自检：sched.sh check 逐档列出未知键、值越界、本机缺节点，最后给 OK / FAIL。
  这套检查要是早就有，上面那个 bug 第一次跑就会报出来。WebUI 调度页也有按钮。
  写档位不再「先全量恢复出厂、再写一遍」：只还原上一档写过、这一档不再需要的键。
  同一个档被重复调用时（守护进程每 300s 的抗重置重申），只补被系统改回去的值，不重写
  全部，补了几项记在 runtime/sched.drift。之前同档直接跳过，系统改回去的值补不回来。
  加了值域校验：PELT_MULTIPLIER 只认 1/2/4，比例类 0-100，RT 预算 1-1000000。越界不写，
  记日志并落到 runtime/sched.badkeys，防止手改 conf 把设备写挂。
  游戏档 RT 预算从 1000000 收回到 950000（官方 Android 默认，留 5% 给普通任务）。
  取消 RT 上限换不到可测的帧率收益，但 RT 线程跑飞时会饿死普通任务。
  节点表补了通用内核 sysctl：sched_util_clamp_min、sched_latency_ns、sched_min_granularity_ns、
  sched_wakeup_granularity_ns、sched_base_slice_ns、sched_rt_period_us。按探测式写入，
  本机 6.6 内核多数没有这些节点，没有就跳过。EEVDF 的 base_slice、latency_nice 属于
  6.12+/6.13+ 的特性，而且 latency_nice 要 sched_setattr 系统调用，纯 shell 落不了地，没做。
  WebUI 调度页新增「调度层节点」卡：本机哪些节点可用、当前值、缺失名单，加重新探测和
  档位自检两个按钮。

v1.1.0 (2026-09-25)
  守护进程减开销：前台应用和亮灭屏改用系统事件流驱动，不再每轮跑两次 dumpsys。
  实测 dumpsys activity top 单次约 900ms、dumpsys power 约 50ms，一轮 5s 里
  有近 0.95s 卡在这里，现在主循环只读两个小文件；事件流不可用时自动回退 dumpsys。
  循环内的读取改成 shell 内建 read（实测单次 fork 约 13ms，原来一次调度快照要起
  15 个 cat）；场景配置从每轮解析改成场景变化或 30s 才重载。
  WebUI 换成 QQ 风格：底部四个 Tab（状态 / 调度 / 触控 / 我的）、圆角分组卡片行、
  顶部大标题。主题精简成浅色 / 深色两档，去掉原来的四色主题和双布局。

v1.0.1 (2026-09-25)
  精简 WebUI 轮询负载，每轮 ksu.exec 从 7 次降到 2 次。
  设备常量（版本 / SELinux / 物理内存 / 核心数）只读一次并缓存；
  方案名并入主批读；ZRAM 改成 30s 一轮；日志改成 15s 一轮且不再阻塞主状态；
  帧率原始表只在 GPU 子页打开时才取（之前每轮都传整份 fpsgo_status）。
  呼吸灯动画由 box-shadow 改成 opacity，去掉 transition: all。

v1.0.0 (2026-09-25)
  模块改名 Falling-MT6991（原 PerfMTK-MT6991），id、模块路径、守护进程名一并改。
  清理开发期堆在注释和文档里的流水记录。

v9.3.1 (2026-09-25)
  省电档也保持 slim-scx 参与（SCX_GOV_CTRL 改成 1）。
  顺便说明：这个键是 slim-scx 轻载参与开关，不是风驰总开关，之前放在调度信息里
  写着"scx 参与"，容易看成风驰开关。

v9.3.0 (2026-09-24)
  实验室上线：用户态调速器（实验功能，默认关）。
  切 userspace governor，每 20ms 采样各簇利用率自算频率写 scaling_setspeed，
  升频立即、降频渐进，温度超限自动压频；频率边界仍受档位限制。
  开机探测内核支不支持，不支持就禁用开关；切换或写值失败会自动还原 governor。

v9.2.0 (2026-09-24)
  游戏包名名单改成你自己维护（WebUI 触控页填）。
  命中名单或检测到官方风驰时，模块整体让路不碰 CPU，只切采样率。

v9.1.0 (2026-09-24)
  修掉"进游戏风驰一下子被顶成 performance"：官方风驰生效期间模块不再写任何 CPU 参数。

v9.0.0 (2026-09-24)
  移除游戏调度（风驰 / 调校表 / 类别识别 / 绑核 / 预加载），游戏 CPU 交给官方。
  去负优化功能一并删除。

v7.0.x - v8.x (2026-09)
  全领域智能调度、温控基线化（降频不再一路降到底）、ZRAM 并入、主题系统与双布局。

v5.x - v6.x (2026-09)
  控制链四层定型、配置方案、游戏检测重构、WebUI 性能优化。