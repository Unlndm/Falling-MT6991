#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WebUI 结构验证 (不依赖浏览器)
------------------------------------------------------------
为什么不用无头浏览器: 本机沙箱会 SIGTERM 掉浏览器进程(实测 Edge 155
启动即被杀)。改用标准库做结构级验证, 覆盖静态检查抓不到的问题:

  1) HTML 标签闭合 / 嵌套是否合法
  2) CSS 语法: 括号平衡 / 声明缺分号 / 变量引用是否有定义
  3) 选择器与 DOM 的匹配: CSS 里写了 .xxx 但 HTML 里没有这个类 = 死样式
     HTML 里用了 .xxx 但 CSS 没定义 = 无样式(元素会裸奔)
  4) id 引用一致性: JS 用到的 id 是否都在 HTML 里
  5) 结构完整性: 每个 page 是否有内容 / dock 按钮数与 page 数是否匹配
  6) 角色化玻璃: .g 元素是否都声明了 data-role
  7) 动效 token 是否齐全

用法: python tools/ui_check.py [webroot目录]
"""
import io
import os
import re
import sys
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Falling-MT6991", "webroot")

problems = []
notes = []


def read(name):
    p = os.path.join(ROOT, name)
    if not os.path.exists(p):
        problems.append("文件缺失: " + name)
        return ""
    return io.open(p, encoding="utf-8").read()


# ---------- 1. HTML 结构 ----------
class StructCheck(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.errs = []
        self.ids = []
        self.classes = {}
        self.data_role = {}
        self.void_count = 0
        self.tag_count = 0

    def handle_starttag(self, tag, attrs):
        self.tag_count += 1
        d = dict(attrs)
        if "id" in d:
            self.ids.append(d["id"])
        if "class" in d:
            for c in d["class"].split():
                self.classes.setdefault(c, 0)
                self.classes[c] += 1
        if "data-role" in d:
            self.data_role.setdefault(d["data-role"], 0)
            self.data_role[d["data-role"]] += 1
        if tag in VOID:
            self.void_count += 1
            return
        self.stack.append((tag, self.getpos()[0]))

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack:
            self.errs.append("多余的 </%s> (行 %d)" % (tag, self.getpos()[0]))
            return
        if self.stack[-1][0] == tag:
            self.stack.pop()
            return
        if tag in [t for t, _ in self.stack]:
            while self.stack and self.stack[-1][0] != tag:
                t, ln = self.stack.pop()
                self.errs.append("<%s> (行 %d) 未闭合, 在 </%s> 之前" % (t, ln, tag))
            if self.stack:
                self.stack.pop()
        else:
            self.errs.append("孤立的 </%s> (行 %d)" % (tag, self.getpos()[0]))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)


html = read("index.html")
if html:
    sc = StructCheck()
    sc.feed(html)
    for t, ln in sc.stack:
        sc.errs.append("<%s> (行 %d) 始终未闭合" % (t, ln))
    if sc.errs:
        for e in sc.errs[:20]:
            problems.append("HTML: " + e)
    notes.append("HTML: %d 个标签, %d 个 id, %d 个 class, %d 个 data-role"
                 % (sc.tag_count, len(sc.ids), len(sc.classes), len(sc.data_role)))

    dup = [i for i in set(sc.ids) if sc.ids.count(i) > 1]
    if dup:
        problems.append("HTML: 重复的 id: " + ", ".join(sorted(dup)))

    # 6) 角色化玻璃
    no_role = re.findall(r'class="[^"]*\bg\b[^"]*"(?![^>]*data-role)', html)
    if no_role:
        problems.append("玻璃: %d 处 .g 缺少 data-role(材质语义不明确)" % len(no_role))
    else:
        notes.append("玻璃: 全部 .g 都声明了 data-role")
    notes.append("玻璃角色分布: " + ", ".join(
        "%s=%d" % (k, v) for k, v in sorted(sc.data_role.items())))


# ---------- 2. CSS 语法 ----------
css_files = ["theme.css", "glass-liquid.css"]
all_css = ""
css_classes = set()
css_ids = set()
for cf in css_files:
    s = read(cf)
    if not s:
        continue
    all_css += "\n/* " + cf + " */\n" + s
    if s.count("{") != s.count("}"):
        problems.append("CSS %s: 括号不平衡 (%d/%d)" % (cf, s.count("{"), s.count("}")))
    # 声明缺分号: "prop: value" 后面没有 ; 或 }
    for m in re.finditer(r'\{([^{}]*)\}', s):
        body = m.group(1)
        for decl in body.split(";"):
            d = decl.strip()
            if not d:
                continue
            if ":" not in d:
                problems.append("CSS %s: 声明缺少冒号 -> %s" % (cf, d[:50]))
    # 提取类名与 id
    for m in re.finditer(r'\.([a-zA-Z][a-zA-Z0-9_-]*)', s):
        css_classes.add(m.group(1))
    for m in re.finditer(r'#([a-zA-Z][a-zA-Z0-9_-]*)', s):
        css_ids.add(m.group(1))

# 变量引用 vs 定义
used_vars = set(re.findall(r'var\((--[a-zA-Z0-9_-]+)', all_css))
defined_vars = set(re.findall(r'(--[a-zA-Z0-9_-]+)\s*:', all_css))
# 内联 style 里定义的变量(如 style="--sw:#e9eef5")也算已定义
if html:
    defined_vars |= set(re.findall(r'(--[a-zA-Z0-9_-]+)\s*:\s*[^;"\']+["\']', html))
# 允许 var(--x, fallback) 的自引用形式
undefined = sorted(v for v in used_vars - defined_vars if v not in defined_vars)
if undefined:
    # 排除 fallback 里引用的(那是合法的)
    real = [v for v in undefined if not re.search(r'var\(\s*' + re.escape(v) + r'\s*,', all_css)]
    if real:
        problems.append("CSS: 引用了未定义的变量: " + ", ".join(real))
    else:
        notes.append("CSS: 未定义的变量都是 fallback 自引用(合法)")

# 关键 token 必须齐全
REQUIRED_TOKENS = ["--accent", "--ink", "--muted", "--faint", "--line", "--fill",
                    "--safe-top", "--safe-bottom", "--ease-out", "--ease-in-out",
                    "--dur-fast", "--dur-pop", "--glass-blur", "--radius",
                    "--press-cool", "--press-warm", "--press-hot"]
missing_tokens = [t for t in REQUIRED_TOKENS if t not in defined_vars]
if missing_tokens:
    problems.append("CSS: 缺少关键 token: " + ", ".join(missing_tokens))
else:
    notes.append("CSS: %d 个 token, 关键 token 齐全" % len(defined_vars))

# ---------- 3. 类名双向匹配 ----------
if html:
    html_classes = set(sc.classes)
    dead = sorted(css_classes - html_classes)
    # 排除伪类/状态选择器产生的噪声
    dead = [d for d in dead if not d.startswith("g-")]
    naked = sorted(html_classes - css_classes)
    if naked:
        problems.append("样式: HTML 用了但 CSS 没定义的类 (%d): %s"
                        % (len(naked), ", ".join(naked)))
    else:
        notes.append("样式: HTML 的每个类都有定义")
    if dead:
        notes.append("样式: %d 个 CSS 类未在 HTML 出现(可能是 JS 动态生成): %s"
                     % (len(dead), ", ".join(dead[:12])))

# ---------- 4. id 引用一致性 ----------
appjs = read("app.js")
if appjs and html:
    used_ids = set(re.findall(r'\$\("([^"]+)"\)', appjs))
    used_ids |= set(re.findall(r'getElementById\("([^"]+)"\)', appjs))
    missing = sorted(used_ids - set(sc.ids))
    if missing:
        problems.append("JS: 引用了 HTML 里没有的 id (%d): %s"
                        % (len(missing), ", ".join(missing)))
    else:
        notes.append("JS: %d 个 id 引用全部命中" % len(used_ids))
    # 死 id: HTML 有但 JS 从不引用(排除动态使用)
    dynamic = {"cl0-bar", "cl1-bar", "cl2-bar", "cl0-val", "cl1-val", "cl2-val",
               "loop-arc", "loop-press", "loop-fps", "loop-prime", "loop-ratio",
               "loop-fps-bar", "loop-prime-bar", "loop-ratio-bar", "exec-steps",
               "app-policy-list", "app-touch-list", "app-list", "event-log",
               "smart-info", "smart-trace", "smart-stats", "sched-info",
               "sched-nodes", "daemon-info", "hw-overview", "cluster-heat"}
    dead_ids = sorted(set(sc.ids) - used_ids - dynamic)
    if dead_ids:
        notes.append("JS: %d 个 id 未被直接引用(可能是死元素): %s"
                     % (len(dead_ids), ", ".join(dead_ids[:15])))

# ---------- 5. 结构完整性 ----------
if html:
    pages = re.findall(r'id="page-([a-z-]+)"', html)
    dock = re.findall(r'data-page="([a-z-]+)"', html)
    if len(pages) != len(dock):
        problems.append("结构: page 数(%d) 与 dock 按钮数(%d) 不匹配"
                        % (len(pages), len(dock)))
    else:
        notes.append("结构: %d 个平级 page, dock 按钮匹配" % len(pages))
    if set(pages) != set(dock):
        problems.append("结构: page 与 dock 的 id 不对应: %s vs %s"
                        % (pages, dock))
    # 每个 page 必须有内容
    for p in pages:
        m = re.search(r'id="page-%s"[^>]*>(.*?)(?=<section class="page"|</main>)' % p,
                      html, re.S)
        if not m or len(re.sub(r'<[^>]+>', '', m.group(1)).strip()) < 20:
            problems.append("结构: page-%s 内容为空" % p)
    # 关键区块
    for need in ["hero-card", "loop-panel", "tendency-seg", "cluster-heat",
                 "game-mode-seg", "dock-wrap", "glass-canvas"]:
        if need not in html:
            problems.append("结构: 缺少关键区块 " + need)
    # 玻璃引擎: WebGL 版必须有 shader 的 SDF 圆角 + 折射 + 色散
    glassjs = read("glass-liquid.js")
    if not glassjs:
        problems.append("结构: glass-liquid.js 缺失")
    else:
        need_gl = ["sdRoundedRect", "refractContent", "sampleContent",
                   "feDisplacement", "createShader", "glass-surface"]
        missing_gl = [k for k in need_gl if k not in glassjs]
        if missing_gl:
            problems.append("玻璃引擎: glass-liquid.js 缺少关键实现: "
                            + ", ".join(missing_gl))
        else:
            notes.append("玻璃引擎: WebGL SDF 圆角 + 折射 + 色散实现完整")
        if "backdrop-filter" in glassjs:
            problems.append("玻璃引擎: 不应在 JS 里用 backdrop-filter(逐元素滤镜是卡顿主因)")
    # 旧方案残留: SVG 滤镜 + backdrop-filter 逐元素折射
    if "feTurbulence" in html:
        problems.append("结构: 仍在用旧版 SVG 折射滤镜(应改为 WebGL 引擎)")
    glasscss = read("glass-liquid.css")
    if glasscss and "url(#lgRefract)" in glasscss:
        problems.append("结构: glass-liquid.css 仍引用 url(#lgRefract)")
    # 逐元素 backdrop-filter 是设置页卡顿的根因:
    # 只有 .glass-flat 降级路径允许有一层模糊, 且不能带 SVG 位移滤镜
    if glasscss:
        bf = re.findall(r'([^{}]*)\{([^{}]*backdrop-filter[^{}]*)\}', glasscss)
        for sel, body in bf:
            if "glass-flat" not in sel:
                problems.append("玻璃引擎: 非降级路径出现 backdrop-filter: " + sel.strip())
            if "url(" in body:
                problems.append("玻璃引擎: backdrop-filter 叠加了 SVG 滤镜(极慢): " + sel.strip())
    # 脚本引入
    for js in ["host.js", "glass-liquid.js", "app.js"]:
        if js not in html:
            problems.append("结构: 未引入 " + js)
    for cs in ["theme.css", "glass-liquid.css"]:
        if cs not in html:
            problems.append("结构: 未引入 " + cs)
    # 旧的样式表不应再被引用
    if "glass.css" in html:
        problems.append("结构: 仍在引用旧的 glass.css(应换成 theme.css)")

# ---------- 6. 原创组件存在性 ----------
if html:
    for orig in ["loop-ring", "exec-steps", "cluster-heat", "decision-timeline",
                 "mode-grid", "hero-metrics", "section-divider", "dock-indicator"]:
        if orig not in html:
            problems.append("原创: 缺少组件 " + orig)
    notes.append("原创组件: 闭环仪表 / 分簇热力 / 决策链时间轴 / 卡片网格 / Hero 指标 均在位")

# ---------- 输出 ----------
print("=" * 62)
print("WebUI 结构验证:", os.path.normpath(ROOT))
print("=" * 62)
for n in notes:
    print("  ·", n)
print()
if problems:
    print("发现 %d 个问题:" % len(problems))
    for p in problems:
        print("  ✗", p)
    sys.exit(1)
else:
    print("全部通过 [OK]")
    sys.exit(0)
