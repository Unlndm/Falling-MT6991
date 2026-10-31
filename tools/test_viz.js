/* ============================================================
   原创可视化的逻辑测试 (无浏览器, 最小 DOM 模拟)
   ------------------------------------------------------------
   验证 renderLoop / renderClusterHeat / renderDecisionTimeline
   的输出是否正确 —— 这些是新写的最容易出错的渲染逻辑。

   用法: node tools/test_viz.js
   ============================================================ */
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "Falling-MT6991", "webroot");

// ---------- 最小 DOM ----------
const store = {};
function el(id) {
  if (!store[id]) {
    store[id] = {
      id, textContent: "", innerHTML: "", hidden: false,
      style: {}, dataset: {}, classList: {
        _s: new Set(),
        add(...c) { c.forEach(x => this._s.add(x)); },
        remove(...c) { c.forEach(x => this._s.delete(x)); },
        toggle(c, on) { on ? this._s.add(c) : this._s.delete(c); },
        contains(c) { return this._s.has(c); }
      },
      querySelectorAll: () => [],
      querySelector: () => null,
      _attrs: {},
      getAttribute(k) { return k in this._attrs ? this._attrs[k] : null; },
      setAttribute(k, v) { this._attrs[k] = v; },
      appendChild: () => {}
    };
  }
  return store[id];
}
global.document = {
  getElementById: id => (id in store ? store[id] : (store[id] = el(id))),
  querySelector: sel => (sel === "#smart-info" ? el("smart-info")
    : sel.startsWith("#") ? el(sel.slice(1)) : null),
  querySelectorAll: () => [],
  documentElement: el("html"),
  body: el("body"),
  addEventListener: () => {}
};
global.window = {
  matchMedia: () => ({ matches: false, addEventListener: () => {} }),
  addEventListener: () => {},
  dispatchEvent: () => {},
  localStorage: { getItem: () => null, setItem: () => {} }
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.navigator = { vibrate: () => true };
global.setTimeout = setTimeout;

// ---------- 载入被测函数 ----------
const src = fs.readFileSync(path.join(ROOT, "app.js"), "utf8");
// 只取需要的函数: 用正则抽出这几个函数的源码
function extract(name) {
  const re = new RegExp(
    "^(?:async )?function " + name + "\\([^)]*\\)\\s*\\{", "m");
  const m = re.exec(src);
  if (!m) throw new Error("找不到函数 " + name);
  let i = m.index, depth = 0, started = false;
  for (; i < src.length; i++) {
    if (src[i] === "{") { depth++; started = true; }
    else if (src[i] === "}") {
      depth--;
      if (started && depth === 0) return src.slice(m.index, i + 1);
    }
  }
  throw new Error("函数体未闭合 " + name);
}
const need = ["pressColor", "renderLoop", "renderClusterHeat", "renderDecisionTimeline"];
const code = need.map(extract).join("\n\n");
const ZH = '{ performance:"性能", balanced:"均衡", powersave:"省电", "powersave+":"极限省电", game_medium:"中度游戏" }';
const escFn = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const dollar = id => document.getElementById(id);
// 模块级常量: 压力环周长(r=33)
const RING_C = (2 * Math.PI * 33).toFixed(1);
eval(code + "\nvar ZH_PROFILE = " + ZH + ";\nvar esc = escFn;\nvar $ = dollar;\nvar LOOP_RING_C = " + RING_C + ";");

// ---------- 断言 ----------
let pass = 0, fail = 0;
function ok(name, expect, got) {
  const e = String(expect), g = String(got);
  if (e === g) { pass++; console.log("  PASS " + name); }
  else { fail++; console.log("  FAIL " + name + "\n        期望: " + e + "\n        实得: " + g); }
}
function okHas(name, needle, hay) {
  if (String(hay).indexOf(needle) >= 0) { pass++; console.log("  PASS " + name); }
  else { fail++; console.log("  FAIL " + name + "\n        应包含: " + needle + "\n        实得: " + String(hay).slice(0, 200)); }
}
function okNotHas(name, needle, hay) {
  if (String(hay).indexOf(needle) < 0) { pass++; console.log("  PASS " + name); }
  else { fail++; console.log("  FAIL " + name + " (不应包含 " + needle + ")"); }
}

console.log("=== 压力配色 ===");
ok("低压力=冷色", "var(--press-cool)", pressColor(10));
ok("中压力=暖色", "var(--press-warm)", pressColor(50));
ok("高压力=热色", "var(--press-hot)", pressColor(80));

console.log("\n=== 闭环仪表 ===");
// 场景 1: 有完整 loop.state
renderLoop({
  sm: { fps: "55", prime: "92", temp: "52000", psi: "35" },
  ratio: 85,
  loop: { press: "78", level: "3", ema: "55" }
});
ok("压力环 offset(78%)", (207.3 * (1 - 0.78)).toFixed(1), el("loop-arc").getAttribute("stroke-dashoffset"));
ok("压力环 stroke", "var(--press-hot)", el("loop-arc").style.stroke);
ok("压力数值", "78", el("loop-press").textContent);
ok("帧率显示", "55%", el("loop-fps").textContent);
ok("帧率条宽", "55%", el("loop-fps-bar").style.width);
ok("帧率条变色(55<60=热)", "var(--press-hot)", el("loop-fps-bar").style.background);
ok("大核显示", "92%", el("loop-prime").textContent);
ok("大核条变色(92>=90=热)", "var(--press-hot)", el("loop-prime-bar").style.background);
ok("争用显示", "35%", el("loop-psi").textContent);
ok("争用条宽", "35%", el("loop-psi-bar").style.width);
ok("争用条变色(35>=20=暖)", "var(--press-warm)", el("loop-psi-bar").style.background);
ok("温控比例显示", "85%", el("loop-ratio").textContent);
ok("温控条宽(降了15%)", "15%", el("loop-ratio-bar").style.width);
ok("执行器状态", "执行器 L3", el("loop-state").textContent);

// 场景 2: 无 loop.state, 用帧率+大核合成
renderLoop({ sm: { fps: "95", prime: "10" }, ratio: 100, loop: {} });
// f = 100-95 = 5, pr = max(0,10-60)=0 -> 5*0.7 = 3.5 -> 4
ok("无 loop.state 时合成压力", "4", el("loop-press").textContent);
ok("温控全速显示", "全速", el("loop-ratio").textContent);
ok("温控条宽(全速=0)", "0%", el("loop-ratio-bar").style.width);

// 场景 3: 完全没有数据
renderLoop({ sm: {}, ratio: 100, loop: {} });
ok("无数据时压力为 0", "0", el("loop-press").textContent);
ok("无数据时帧率 --", "--", el("loop-fps").textContent);
ok("无数据时争用 --", "--", el("loop-psi").textContent);

console.log("\n=== 分簇热力 ===");
renderClusterHeat({ cluster0: "55", cluster1: "30", cluster2: "12" });
ok("小核值", "55%", el("cl0-val").textContent);
ok("中核值", "30%", el("cl1-val").textContent);
ok("大核值", "12%", el("cl2-val").textContent);
ok("小核条宽", "55%", el("cl0-bar").style.width);
ok("小核条变色(55<70=冷)", "var(--press-cool)", el("cl0-bar").style.background);

// 只剩两簇时重新命名
renderClusterHeat({ cluster0: "-1", cluster1: "40", cluster2: "80" });
ok("两簇时大核条宽", "80%", el("cl2-bar").style.width);
ok("两簇时大核变色(80=暖)", "var(--press-warm)", el("cl2-bar").style.background);

console.log("\n=== 决策链时间轴 ===");
renderDecisionTimeline("");
okHas("空历史显示提示", "还没有换过档", el("smart-trace").innerHTML);

// 用 lib/smart.sh 的真实格式:
//   "10-24 17:25:00 from>to 原因 score=N t=N busy=N prime=N fps=N psi=N"
// trace 是追加写的: 第一行最早, 最后一行最新。UI 倒序 => 最新的在最上。
renderDecisionTimeline(
  "10-24 17:25:00 performance>powersave 温度过高 score=30 t=58000 busy=40 prime=20 fps=98 psi=12\n" +
  "10-24 17:30:00 balanced>performance 帧率不足 score=45 t=62000 busy=85 prime=92 fps=55 psi=30");
okHas("含换档方向", "均衡 → 性能", el("smart-trace").innerHTML);
okHas("含降档方向", "性能 → 省电", el("smart-trace").innerHTML);
okHas("原因文字保留", "帧率不足", el("smart-trace").innerHTML);
okNotHas("原因不含裸 key=value", "score=45", el("smart-trace").innerHTML);
okHas("温度信号(毫度转摄氏度)", "温度 58°C", el("smart-trace").innerHTML);
okHas("高温信号标 hot", "dt-sig hot", el("smart-trace").innerHTML);
okHas("低分信号标 warm", "dt-sig warm", el("smart-trace").innerHTML);
okHas("帧率信号", "帧率 55%", el("smart-trace").innerHTML);
okHas("低帧率标 hot", "dt-sig hot", el("smart-trace").innerHTML);
okHas("争用信号", "争用 30%", el("smart-trace").innerHTML);
okNotHas("原因不含争用裸 key=value", "psi=30", el("smart-trace").innerHTML);
okHas("降档方向标记 down", 'data-dir="down"', el("smart-trace").innerHTML);
okHas("升档方向标记 up", 'data-dir="up"', el("smart-trace").innerHTML);
ok("最近的在最前(倒序)", "PASS",
  el("smart-trace").innerHTML.indexOf("均衡 → 性能") <
  el("smart-trace").innerHTML.indexOf("性能 → 省电") ? "PASS" : "FAIL");

console.log("\n=== 结果 ===");
console.log("通过 " + pass + " / 失败 " + fail);
process.exit(fail ? 1 : 0);
