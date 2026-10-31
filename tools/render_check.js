/* ============================================================
   WebUI 渲染验证 (本地无头 Edge)
   ------------------------------------------------------------
   目的: 静态检查看不出「元素重叠 / 样式没生效 / JS 运行时抛错」。
   这里真实渲染页面, 收集 console 错误 + 页面异常, 并逐页截图。

   用法: node tools/render_check.js <webroot目录> <输出目录>
   ============================================================ */
const puppeteer = require("puppeteer-core");
const path = require("path");
const fs = require("fs");

const WEBROOT = process.argv[2] || path.join(__dirname, "..", "Falling-MT6991", "webroot");
const OUT = process.argv[3] || path.join(__dirname, "..", "_render");

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await puppeteer.launch({
    executablePath: EDGE,
    headless: "new",
    args: [
      "--allow-file-access-from-files",
      "--disable-gpu",
      "--hide-scrollbars",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-software-rasterizer",
      "--user-data-dir=C:////Users////76578////AppData////Local////Temp////edge-pptr"
    ],
    protocolTimeout: 60000
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 412, height: 915, deviceScaleFactor: 2 });

  const errors = [];
  page.on("console", m => {
    if (m.type() === "error") errors.push("[console] " + m.text());
  });
  page.on("pageerror", e => errors.push("[pageerror] " + e.message));

  const url = "file:///" + path.resolve(WEBROOT, "index.html").replace(/\\/g, "/");
  await page.goto(url, { waitUntil: "networkidle0" });
  await new Promise(r => setTimeout(r, 900));

  const PAGES = ["overview", "schedule", "touch", "settings"];
  for (const p of PAGES) {
    await page.evaluate(id => {
      const btn = document.querySelector(`.dock button[data-page="${id}"]`);
      if (btn) btn.click();
    }, p);
    await new Promise(r => setTimeout(r, 700));
    const file = path.join(OUT, p + ".png");
    await page.screenshot({ path: file, fullPage: true });
    console.log("截图:", p);
  }

  // 深色模式
  await page.evaluate(() => {
    const b = document.querySelector('#theme-picker [data-theme="dark"]');
    if (b) b.click();
  });
  await new Promise(r => setTimeout(r, 700));
  await page.screenshot({ path: path.join(OUT, "overview-dark.png"), fullPage: true });
  console.log("截图: overview-dark");

  // 布局体检: 元素溢出 / 文字截断 / 玻璃角色缺失
  const audit = await page.evaluate(() => {
    const out = { overflow: [], noRole: [], zeroSize: [], title: document.title };
    const vw = document.documentElement.clientWidth;
    document.querySelectorAll(".g, .panel, .mode-card, .kv-row, .hero-card, .loop-panel").forEach(el => {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) {
        out.zeroSize.push(el.className);
        return;
      }
      if (r.right > vw + 2) {
        out.overflow.push({ cls: el.className, right: Math.round(r.right), vw });
      }
    });
    // 玻璃角色: .g 但没有 data-role 的(会有样式但没有材质语义)
    document.querySelectorAll(".g").forEach(el => {
      if (!el.getAttribute("data-role")) out.noRole.push(el.className);
    });
    // 关键内容是否渲染出内容(不是空)
    const key = {};
    ["hero-mode", "loop-press", "loop-fps", "cluster-heat", "smart-info", "smart-trace", "exec-steps"].forEach(id => {
      const e = document.getElementById(id);
      key[id] = e ? (e.textContent || "").trim().slice(0, 40) : "(缺失)";
    });
    out.key = key;
    out.dockBtns = document.querySelectorAll(".dock button").length;
    out.pages = document.querySelectorAll(".page").length;
    out.activePage = document.querySelector(".page.active") ? document.querySelector(".page.active").id : "(无)";
    return out;
  });

  console.log("\n=== 布局体检 ===");
  console.log("标题:", audit.title);
  console.log("dock 按钮:", audit.dockBtns, "| page 数:", audit.pages, "| 当前:", audit.activePage);
  console.log("零尺寸元素:", audit.zeroSize.length ? audit.zeroSize : "无 [OK]");
  console.log("横向溢出:", audit.overflow.length ? audit.overflow.slice(0, 6) : "无 [OK]");
  console.log("无 data-role 的 .g:", audit.noRole.length ? audit.noRole.slice(0, 6) : "无 [OK]");
  console.log("关键内容:");
  Object.keys(audit.key).forEach(k => console.log("   " + k + " = " + JSON.stringify(audit.key[k])));

  console.log("\n=== JS 错误 ===");
  console.log(errors.length ? errors.slice(0, 20).join("\n") : "无 [OK]");

  await browser.close();
  process.exit(errors.length ? 1 : 0);
})().catch(e => { console.error("渲染失败:", e); process.exit(2); });
