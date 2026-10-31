#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成自包含的 WebUI 预览页
------------------------------------------------------------
用途: 把 webroot 的 HTML/CSS/JS 内联成一个单文件, 双击就能在浏览器里
看到真实渲染效果(不需要 KernelSU, 走预览模式的模拟数据)。

为什么需要: 本机沙箱会杀掉浏览器进程(Edge/Playwright 都试过, SIGTERM),
无法在开发机上自动截图验证。生成预览页让用户在自己的浏览器里看。

用法: python tools/make_preview.py [webroot目录] [输出文件]
"""
import io
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Falling-MT6991", "webroot")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "release", "webui-preview.html")


def read(name):
    p = os.path.join(ROOT, name)
    if not os.path.exists(p):
        print("跳过(不存在):", name)
        return None
    return io.open(p, encoding="utf-8").read()


html = read("index.html")
css1 = read("theme.css")
css2 = read("glass-liquid.css")
js1 = read("host.js")
js2 = read("glass-liquid.js")
js3 = read("app.js")

if not html:
    print("index.html 不存在, 无法生成预览")
    sys.exit(1)

# 内联 CSS
# 版本号用正则匹配, 不要写死 —— index.html 的 ?v=N 会随版本变化,
# 写死会导致替换失效, 预览页里仍是外链(双击打开就白屏)。
import re as _re


def inline(css_name, tag_pattern):
    global html
    css = read(css_name)
    if not css:
        return
    html = _re.sub(tag_pattern,
                  lambda m: "<style>\n%s\n</style>" % css,
                  html, count=1)


inline("theme.css", r'<link rel="stylesheet" href="theme\.css(?:\?v=\d+)?">')
inline("glass-liquid.css", r'<link rel="stylesheet" href="glass-liquid\.css(?:\?v=\d+)?">')

# 内联 JS
for js_name in ["host.js", "glass-liquid.js", "app.js"]:
    code = read(js_name)
    if not code:
        continue
    html = _re.sub(r'<script src="%s(?:\?v=\d+)?"></script>' % _re.escape(js_name),
                   lambda m: "<script>\n%s\n</script>" % code,
                   html, count=1)

# 预览模式: 强制走模拟数据分支(没有 window.ksu 时 app.js 自动进预览模式)
# 但要保证 exec 存在。app.js 的 initKsu 在没有 ksu 时会自建模拟 exec, 没问题。
# 唯一的坑: 预览模式调 showToast 提示, 可以接受。

# 顶部加一个预览提示条
BANNER = """
<style>
#pv-banner{
  position:fixed;z-index:999;left:0;right:0;top:0;
  padding:6px 12px;text-align:center;font-size:11px;
  background:rgba(255,159,10,.92);color:#1a1a1c;font-weight:600;
}
body{padding-top:0}
#pv-banner~.top-bar{top:22px}
</style>
<div id="pv-banner">预览模式 · 模拟数据 · 非 KernelSU 环境下渲染</div>
"""

# 插到 <body ...> 之后
html = re.sub(r'(<body[^>]*>)', r'\1' + BANNER, html, count=1)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
io.open(OUT, "w", encoding="utf-8", newline="\n").write(html)
print("预览页已生成: %s" % os.path.normpath(OUT))
print("大小: %.1f KB" % (os.path.getsize(OUT) / 1024.0))
print("双击用浏览器打开即可看到真实渲染效果(4 个页面 + 深色模式)。")
