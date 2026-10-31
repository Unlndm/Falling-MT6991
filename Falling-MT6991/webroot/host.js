/* ============================================================
   Falling-MT6991 宿主适配层 (v3.0.1)

   借鉴 NovaSched-Zen-Edition 的 host.js, 但只取对本项目有用的部分。

   解决三件事:
     1) 全面屏内边距: 宿主能报内边距就报, 不能报就用 env(),
        再不行退回 0 —— CSS 里 --safe-* 已经做了三重 fallback。
     2) 软键盘顶起: 输入框聚焦时视口会变矮, 固定底栏与内容区要跟着让位,
        否则键盘会盖住正在输入的内容。
     3) 多宿主 exec: 主用 KernelSU, 顺带兼容 Magisk / APatch / MMRL。
        命令执行方式各家不一样, 这里统一成一个 Promise 接口。

   注意: 这层只做「环境适配」, 不含任何业务逻辑。
   ============================================================ */
(() => {
  "use strict";
  const root = document.documentElement;

  // 已知宿主: 谁能执行命令、谁支持内边距
  const hostApis = () =>
    [window.ksu, window.magisk, window.apatch, window.KSU, window.mmrl].filter(Boolean);

  let configured = null;
  let frame = 0;

  // ---- 1. 全面屏: 让宿主把内容画到刘海/挖孔下面, 我们自己用安全区让位 ----
  function configureInsets() {
    // NovaSched 的做法: 某些宿主本地提供 insets.css, 把内边距以
    // --window-inset-* 变量暴露出来。CSS 里 --safe-* 已经引用了这组变量,
    // 所以这里只要把样式表挂上就自动生效。
    if (!document.getElementById("host-insets") &&
        location.origin === "https://mui.kernelsu.org") {
      const link = document.createElement("link");
      link.id = "host-insets";
      link.rel = "stylesheet";
      link.href = "/internal/insets.css";
      document.head.appendChild(link);
    }
    const host = hostApis().find(
      api => typeof api.enableEdgeToEdge === "function" || typeof api.enableInsets === "function"
    );
    if (!host || host === configured) return;
    try {
      if (typeof host.enableEdgeToEdge === "function") host.enableEdgeToEdge(true);
      else host.enableInsets(true);
      configured = host;
    } catch (_) {
      // 老宿主自己管安全区, 这里静默跳过即可
    }
  }

  // ---- 2. 视口: 键盘 / 缩放 / 旋转 ----
  function applyViewport() {
    frame = 0;
    configureInsets();

    const viewport = window.visualViewport;
    // 页面被用户放大过时不信任 visualViewport, 用 innerHeight
    const unzoomed = !viewport || Math.abs(viewport.scale - 1) < 0.01;
    const height = unzoomed && viewport && viewport.height > 0 ? viewport.height : window.innerHeight;
    if (height > 0) root.style.setProperty("--app-height", height + "px");
    if (unzoomed && viewport) {
      root.style.setProperty("--app-top", Math.max(0, viewport.offsetTop || 0) + "px");
    } else {
      root.style.setProperty("--app-top", "0px");
    }

    // 键盘是否顶起: 焦点在文本输入框, 且视口明显变矮
    const el = document.activeElement;
    const typing = !!el && !!el.matches && el.matches("input:not([type=range]):not([type=color]), textarea");
    const shrunk = !!viewport && window.innerHeight - viewport.height > 120;
    root.classList.toggle("keyboard-open", typing && shrunk);

    window.dispatchEvent(new Event("falling:viewport"));
  }

  function schedule() {
    if (!frame) frame = requestAnimationFrame(applyViewport);
  }

  for (const name of ["resize", "orientationchange", "pageshow", "focusin", "focusout"]) {
    window.addEventListener(name, schedule, { passive: true });
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", schedule, { passive: true });
    window.visualViewport.addEventListener("scroll", schedule, { passive: true });
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) schedule();
  });

  // ---- 3. 多宿主命令执行 ----
  // KernelSU: window.ksu.exec(cmd, "{}", cbName)  —— 回调挂在 window 上
  // Magisk / APatch: 同名 API 但签名略有差异, 这里逐个探测
  function ksuExec(cmd) {
    return new Promise((resolve, reject) => {
      const cb = "fb_cb_" + Date.now() + "_" + Math.floor(Math.random() * 1e6);
      window[cb] = (errno, stdout, stderr) => {
        delete window[cb];
        resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
      };
      try {
        window.ksu.exec(cmd, "{}", cb);
      } catch (e) {
        delete window[cb];
        reject(e);
      }
    });
  }

  function magiskExec(cmd) {
    return new Promise((resolve, reject) => {
      const cb = "fb_mk_" + Date.now() + "_" + Math.floor(Math.random() * 1e6);
      window[cb] = (errno, stdout, stderr) => {
        delete window[cb];
        resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
      };
      try {
        const api = window.magisk || window.apatch;
        if (api && typeof api.exec === "function") api.exec(cmd, "{}", cb);
        else reject(new Error("no magisk/apatch exec"));
      } catch (e) {
        delete window[cb];
        reject(e);
      }
    });
  }

  // 返回一个能用的 exec, 都没有就返回 null(调用方走预览模式)
  function resolveExec() {
    if (typeof window.ksu !== "undefined" && typeof window.ksu.exec === "function") return ksuExec;
    const alt = window.magisk || window.apatch;
    if (alt && typeof alt.exec === "function") return magiskExec;
    return null;
  }

  window.FallingHost = Object.freeze({
    hosts: hostApis,
    exec: resolveExec(),
    refresh: schedule
  });

  applyViewport();
})();
