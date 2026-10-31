# UI 学习报告：NovaSched-Zen-Edition → Falling-MT6991

参考仓库：`https://github.com/zeng060812-creator/NovaSched-Zen-Edition`
源码 clone 在 `_ref_open/NovaSched-Zen-Edition/`。

---

## 一、两个项目的定位差异（先看清再学）

| | NovaSched-Zen-Edition | Falling-MT6991 |
| --- | --- | --- |
| 形态 | Rust native 调度器 + 完整 WebUI | Magisk/KernelSU 模块 + WebUI |
| WebUI 角色 | **核心入口**，用户主要在这里操作 | 附属面板，「打开看一眼状态」 |
| 用户动作 | 选档位、设规则、翻日志、调外观 | 看状态、改三个开关 |
| 视觉预算 | 可以放 598 行 WebGL 折射器 | 必须跑在 Android WebView 里 |

**结论**：学它的**设计方法、信息架构与交互**（v3.3 起，渲染实现也学）。

> **v3.3 更新**：初稿曾写「不学它的渲染预算」。实机反馈「设置页面非常卡」
> 证伪了这个判断 —— 自己造的 CSS/SVG 滤镜近似版比它的 WebGL 引擎更慢。
> 现已完整移植它的 WebGL 玻璃引擎，详见第二节第 1 条。

---

## 二、逐条对照：学了什么 / 没学什么 / 为什么

### ✅ 学了（已落地）

#### 1. Token 化的设计体系
NovaSched 的 `app.css` 把颜色、间距、圆角、时长、缓动全部收进 `:root`，组件里不写死值，深色模式只覆盖 token。

**落地**：`webroot/theme.css`（新建，58 个 token），旧的 `glass.css` 整个废弃。

```
--accent / --accent-press / --accent-soft   主色三态
--ink / --muted / --faint / --line          文字与分隔线四级
--fill / --fill-strong                      填充两级
--ok / --warn / --err                       功能状态色
--page-pad / --top-h / --dock-h             尺寸刻度
--safe-top / --safe-bottom / ...            安全区（三重 fallback）
--ease-out / --ease-in-out / --ease-spring  缓动三档
--dur-push / --dur-pop / --dur-fast         时长三档
```

#### 2. 角色化玻璃材质（`data-role`）
NovaSched 用一个 `.g` 基类 + `data-role` 决定材质：内容卡、面板、强调、dock 指示器、小胶囊各自不同强度。组件不自己写 `backdrop-filter`。

**落地**：`glass-liquid.css` 里 `.g[data-role="..."]` 六档分级，SVG 折射滤镜的 `scale` 与模糊强度按角色递减。

| role | 用途 | 折射强度 |
| --- | --- | --- |
| `course` | 内容卡片（调度倾向） | 全量 |
| `panel` | 分组面板 | 78% |
| `accent` | 强调卡 | 210% 饱和 |
| `lens` | dock 指示器 | 几乎纯透光 |
| `pill` | 小胶囊 | 60% |
| `dock` | 底部导航 | 110% |

#### 3. 4 个平级 page + 双向滑动转场
NovaSched 是 4 个平级 section，切换时旧页滑出、新页滑入，**每页保留自己的滚动位置**，滚动位置不归零时退化为淡入。

**落地**：替换掉原来的「主页 + 6 个子页 overlay」结构。新增 `ownedMotion()` 动效所有权管理（新动效开始前取消旧的，避免叠加）与 `prefers-reduced-motion` 全局降级。

```js
out = outgoing.animate([{transform:"none"},{transform:`translateX(${forward?"-12%":"12%"})`,opacity:0}], ...)
inn = incoming.animate([{transform:`translateX(${forward?"18%":"-18%"})`,opacity:0},{transform:"none",opacity:1}], ...)
```

#### 4. 胶囊 dock + 滑动指示器
指示器用 `--tab-index` 做 CSS 平移（0.42s），active 态用 `aria-current` 而非 class。

**落地**：`.dock-wrap` 固定底部居中，`--tab-index` 驱动指示器。

#### 5. Hero 卡片（大字 + 白话说明 + 指标格）
`.hero-card` 的结构是「小标签 / 大标题（30px）/ 说明 / 元信息」。

**落地**：概览页顶部 = 当前档位大字 + 决策原因 + 3 格关键指标（温度/占用/频率）。

#### 6. `section-divider` — 分区标题带实时状态
`标题 + 细线 + 右侧状态值`。这是 NovaSched 最有信息密度的设计手法：每个分区自己报告状态，不用点进去看。

**落地**：12 个分区全部带状态徽标（`执行器 L3` / `5 簇可用` / `2 条` / `全部可用（18 项）`），由 `renderCounts()` 统一刷新。

#### 7. `mode-grid` — 卡片网格而不是分段控件
图标 + 标题 + 白话说明 + 打勾动画（`stroke-dashoffset` 从 24 到 0）。

**落地**：调度倾向从「省电 | 均衡 | 性能」三段控件改成 3 张卡片，每张写清实际影响。

#### 8. 设置页的信息结构
大标题（28px）+ `settings-group` + `setting-row`（图标 + 标题 + 说明 + 开关/箭头）。

**落地**：4 个设置分组，图标用彩色底（blue/green/purple/orange/red）。

#### 9. `role=switch` 按钮而不是 checkbox
`aria-checked` + 滑块位移 + 按下时 `scaleX(1.12)`。

**落地**：新增 `bindSwitch(id, onChange)`，返回 `false` 可否决状态变更。

#### 10. 语义化触感（六种节奏 + 同语义限频）
NovaSched 的 `haptics.js` 定义 select/toggle/tick/success/failure/warning 六种振动模式，同语义有最小间隔（防连点排成队列）。

**落地**：`vib(ms)` 按语义取值，页面切换用 select(8ms)、开关用 toggle(12ms)、自检用 tick(10ms)。

#### 11. 安全区的三重 fallback
`env(safe-area-inset-top, var(--window-inset-top, 0px))` —— 宿主提供的 inset 优先，其次 CSS env，最后 0。

**落地**：`--safe-*` token 全部照抄这个结构。同时修掉了旧版「顶部完全没管安全区」的 bug。

#### 12. 宿主适配层的边界清晰
NovaSched 的 `host.js` 只做环境适配，不含业务逻辑。

**落地**：`host.js` 保持这个边界，并补上它的 `insets.css` 桥接（`mui.kernelsu.org` 场景）。

#### 13. 规则页交互（v3.3 学）
NovaSched 的规则页（`renderRules` + `showRuleEditor`）解决的是同一个问题：
**用户不该手打应用包名**。

落地到我们的「触控 → 应用策略 / 专属采样率」两块：

| NovaSched | 我们的做法 |
| --- | --- |
| `rule-row` 玻璃卡 + `data-color-index` | 同，规则行是 `data-role="course"` 的玻璃卡 |
| 应用名 + 首字母头像 | 同，色相由名字散列（同一 App 永远同色） |
| 应用名走宿主元数据桥 `getPackagesInfo` | 同，优先取 label，取不到退回包名末段 |
| 左滑露出删除（pointer 事件自跟踪位移） | 同，不用 `touchstart`（会与页面滚动打架） |
| 点击行 → 弹窗编辑（包名 + 档位 chips + 删除） | 同，弹窗而不是原生 `confirm` |
| `add-rule` → 选包 | 同，弹窗内「从应用库选择」+ 搜索 |
| 渲染 key 差分（内容没变不重建 DOM） | 同，否则 5s 轮询会让列表闪烁 |
| 空态引导文案 | 同，「还没有应用策略 / 点下方添加」 |

关键细节：NovaSched 的 `renderRules` 里有这样一行注释 ——
「心跳每 2 秒触发一次 render：内容没变时绝不重建 DOM，否则规则页会随心跳闪烁」。
我们踩过同样的坑，所以照抄了这个 key 差分机制。

---

### ❌ 明确没学（以及为什么）

> **v3.3 更新**：本文档初稿（v3.2）曾断言「WebGL 液态玻璃是最大的一个不学」。
> 这个判断后来被**实机反馈证伪**了 —— 用户反馈「设置页面非常卡」，
> 根因之一正是 CSS/SVG 滤镜方案的逐元素滤镜开销。
> 同时用户明确要求「液态玻璃全部用它的」。
> 现已完整移植 NovaSched 的 WebGL 引擎，详见下面第 1 节的补充说明。

#### 1. WebGL 液态玻璃（598 行）—— v3.3 已改为**完整移植**
NovaSched 用一块 WebGL stage 合成 + 手写 GLSL 圆角 SDF 折射 + 光谱色散。

**v3.2 的不学理由（已被证伪）**：
- ~~调度模块的 WebUI 是「打开看一眼状态」，不是欣赏折射~~ → 用户就是要液态玻璃
- ~~Android WebView 上 7 个全屏 canvas + 每帧 shader 是实打实的显存与发热~~
  → 实际它的架构是**一块** stage 复用，纹理有 24MB 上限，
  且 `renderKey` 差分让静止时**零重绘**，不是每帧重画
- ~~它的 `liquid-glass.js` 需要 `invalidate()` 机制持续重绘~~
  → 动画窗口结束即停帧，静止时引擎根本不排帧

**v3.2 的替代方案（已废弃）**：SVG `feTurbulence` + `feDisplacementMap` + 逐元素 `backdrop-filter`。
**为什么必须换掉**：
- 每块玻璃一个 `backdrop-filter` + 一个 SVG 位移滤镜，30+ 玻璃面同时存在时
  每帧都要重新光栅化滤镜 —— 这是「设置页面非常卡」的根因之一
- 指针跟随高光要逐元素 `getBoundingClientRect()` + 写 CSS 变量，
  在 30+ 玻璃面的页面上是典型 layout thrashing，触摸滚动时必卡

**v3.3 的落地**：`webroot/glass-liquid.js` 完整移植 NovaSched 的
`assets/liquid-glass.js`（ZenJooo，"WebGL adapter for Kyant Backdrop's AGSL lens"，
Apache-2.0），角色材质表、纹理 LRU、renderKey 差分全部照搬。

在本项目上的三处改动：
1. **壁纸源**：NovaSched 用外部壁纸图片；我们改成**程序化生成的渐变画布**
   （配色与 `theme.css` 一致），免二进制资源，同时当显示背景与折射采样源。
2. **去掉指针跟随高光**：改由 shader 的边缘 rim 光提供。
3. **可关闭**：`setEnabled(false)` 彻底摘掉 canvas，退回 CSS 半透明，
   不跑 WebGL、不占显存。

新增 `tools/test_glass.js` 做回归（假 WebGL context 计调用数），
断言首帧只画可见页面的面、静止零重绘、切页旧面释放、关闭后零绘制、
纹理缓存有字节上限。

#### 2. 12 色配色板 + 从壁纸取色
装饰性功能，与「看调度状态」无关。

**替代**：我们有自己的**调度状态色板**，且它是**语义**的而非装饰的：

| token | 含义 | 用途 |
| --- | --- | --- |
| `--press-cool` | 压力低 / 温度低 | 蓝 |
| `--press-warm` | 压力中 / 温度偏高 | 橙 |
| `--press-hot` | 压力高 / 温度过高 | 红 |
| `--tier-save/balance/perf` | 档位 | 省电/均衡/性能 |

这套色板和 `--ok/--warn/--err`（功能状态）是**分开的**——前者是物理量，后者是功能状态。

> v3.3 注：玻璃引擎内部的卡片配色板（6 色循环）仍然保留，
> 它只决定玻璃面的折射色调，属于材质参数，不承担语义。

#### 3. 壁纸系统 + 取景框 + 自定义颜色
纯装饰（让用户换壁纸、选取景框、调配色）。

**替代**：程序化渐变画布（`#glass-canvas`）。**这不是装饰，是必需的**——
玻璃后面没有背景就没有折射，液态感会误导。

#### 4. 四档手动选档（powersave/balance/performance/fast）
**这一条必须不学**，是产品定位冲突：我们的模块定位是「全智能自动调度」，调度参数不暴露给用户。学了它就等于把之前删掉的「场景中心/配置方案」又加回来。

我们保留的是**调度倾向**（省电/均衡/性能），语义是「给评分加偏置」而不是「锁档位」——硬规则（息屏/高温/应用策略/游戏保底）不受影响。

#### 5. 规则列表的左滑删除 —— v3.3 已学
**v3.2 的不学理由**：「我们的应用策略是 `apps.conf` 文本配置，用户用编辑器维护」。
**这个理由站不住**：模块本来就提供了 WebUI，用户在 UI 里改配置才是主路径，
让用户去改文本文件是不合理的。

**v3.3 落地**（见下面「规则页交互」一节）：玻璃规则行、应用名 + 彩色头像、
左滑删除、点击进编辑弹窗、从应用库选包、搜索过滤、渲染 key 差分。

#### 6. 完整日志流 + WebSocket 实时推送
我们的日志是守护进程写的单文件，轮询即可。

---

## 三、我们的原创（NovaSched 没有对等物）

调度模块和 NovaSched 讲的不是一回事，所以三个可视化必须自己设计。

### 1. 帧率闭环仪表

NovaSched 的 `engine-meter` 是「一条静态进度条」表达单一度量。我们的调度闭环是多维的：追帧压力、执行器档位、帧率达标率、大核占用、温控降额。

```
┌─────────────┬──────────────────────────────┐
│  ╭─────╮    │ 帧率达标率  ────── 55%          │
│  │ 78 │    │ 大核占用    ────── 92%          │
│  │压力 │    │ 温控降额    ────── 85%          │
│  ╰─────╯    │ ▬▬▬▬ ▬▬▬▬                     │
│             │ ▬▬ ▬▬▬ ▬▬▬▬▬▬  (L0~L4 刻度)   │
└─────────────┴──────────────────────────────┘
```

- 压力环用 SVG 描边，`stroke-dashoffset` 表示压力，颜色随压力冷→暖→热
- 三段条各自独立配色：帧率 <60% 转热色，大核 ≥90% 转热色，降额 >30% 转热色
- 档位刻度 5 格，达成格填充 + 当前格高亮
- **没有 `loop.state` 时**用帧率与���核合成一个参考压力（而不是显示空环）

### 2. 分簇热力

整机占用看不出瓶颈在哪：「小核吃满 + 大核空转」和「三簇各半」是完全不同的两件事，后者需要提频，前者提了也没用。

三条并列条形，一眼看出谁在忙。**簇数不固定**——本机只有两簇时自动重新命名（小核/中核 → 中核/大核），不硬套三档。

### 3. 决策链时间轴

「为什么又降档了」是用户真正想看的东西，不是原始日志行。

```
● 均衡 → 性能                    10-24 17:30:00
  帧率不足
  [分数 45] [温度 62°C] [占用 85%] [帧率 55%]

● 性能 → 省电                    10-24 17:25:00
  温度过高
  [分数 30] [温度 58°C]
```

- 方向用颜色区分（降档红、升档红系里的性能色）
- 信号做成小标签，超阈值自动标 `hot` / `warm`
- 解析严格按 `lib/smart.sh` 的真实写入格式：
  `"10-24 17:25:00 from>to 原因 score= t= busy= prime= fps="`

---

## 四、验证方式（本机环境的限制与应对）

### 遇到的环境限制
本机沙箱会 **SIGTERM 掉浏览器进程**：Edge 155 headless 立即退出（`Code: 0`），`puppeteer-core` 与 `playwright` 都被杀。**无法自动截图验证。**

### 应对：三层验证

| 层 | 工具 | 覆盖 |
| --- | --- | --- |
| 结构 | `tools/ui_check.py`（新增） | HTML 标签闭合/嵌套、CSS 括号与声明、变量引用与定义、**类名双向匹配**、id 引用一致性、page/dock 数量与对应、SVG 滤镜完整性、玻璃角色完整性、原创组件在位 |
| 逻辑 | `tools/test_viz.js`（新增） | 39 项断言：压力配色分档、环长计算、无数据时的合成压力、簇数自适应、毫摄氏度转摄氏度、信号标签分级、倒序 |
| 人工 | `tools/make_preview.py`（新增） | 生成自包含预览页（CSS/JS 全内联），双击在浏览器里看真实渲染 + 4 个页面 + 深色模式 |

### 测试抓到的真实缺陷
`test_viz.js` 抓到：**压力环画的是合成压力，数字却显示 `--`** —— 弧长与读数不一致，用户会困惑。已修（数字与弧长用同一个值）。

另外在写解析时发现 `smart.trace` 的真实格式与我最初假设的完全不同（时间是两段、信号是 key=value），一次写错。**测试先行是必须的**——这正是 NovaSched 用 `CODE_WIKI.md` 记录格式的原因。

---

## 五、最终结构（v3.3）

```
webroot/
  index.html        4 个平级 page + 胶囊 dock + 规则编辑器弹窗
  theme.css         设计体系（token + 角色化玻璃基类 + 规则行样式）
  glass-liquid.css  液态玻璃材质层（.glass-surface 定位 + 降级路径）
  glass-liquid.js   WebGL 液态玻璃引擎（移植 NovaSched 的 AGSL 镜面折射）
  host.js           宿主适配（多宿主 exec、edge-to-edge、安全区、键盘）
  app.js            业务逻辑（含 3 个原创可视化 + NovaSched 风格规则页）
tools/
  test_glass.js     玻璃引擎回归测试（假 WebGL context 计调用数）
  ui_check.py       结构验证（v3.3 起改为验证 WebGL 架构）
```

**验证结果（v3.3.0）**：
- JS 语法：3 个文件全过
- `ui_check.py`：全部通过（534 标签 / 146 id / 104 class / 6 data-role）
- `test_viz.js`：39 项断言全过
- `test_glass.js`：6 组断言全过（首帧 / 静止零重绘 / 切页 / 关闭 / 重开 / 纹理上限）
- 后端六套 selftest：smart / sched / io / thermal / loop / config 全部通过
- 包内 59 个文件逐字节一致，versionCode 3300

**浏览器实测**（Edge + WorkBuddy Browser）：
- 4 个页面均正常渲染，玻璃折射/色散生效（浅色与深色都验过）
- dock 四页签图标正常（v3.2 遗留的 `.g > *` 覆盖 absolute 的 bug 已修）
- 应用策略：规则行、编辑弹窗、档位 chips、从应用库选包全流程可用
- 弹窗无重影（去掉 backdrop-filter 后）
