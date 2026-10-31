/* WebGL 液态玻璃引擎回归测试
 * ------------------------------------------------------------
 * 不依赖真实 GPU: 用假的 WebGL context 记录调用次数。
 * 关注的是「调度与缓存的不变量」, 不是像素。
 *
 * 断言:
 *   1) 引擎初始化成功, runtime 为 WebGL
 *   2) 首次渲染: 每个可见玻璃面各画一次
 *   3) 静止时零重绘(不重画、不重传纹理、不重设 stage 尺寸)
 *   4) 页面切换: 新页面的面被画, 旧页面的面被释放
 *   5) 关闭玻璃: canvas 全部摘掉, 不再有任何绘制
 *   6) 纹理缓存有字节上限, 不会无限增长
 *
 * 用法: node tools/test_glass.js
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const ROOT = path.resolve(__dirname, '..');
const WEB = path.join(ROOT, 'Falling-MT6991', 'webroot');

function makeHost() {
  /* 极简 DOM: 只需要引擎用到的那几个 API */
  const listeners = {};
  const metrics = { draws: 0, uploads: 0, creates: 0, resizes: 0, copies: 0 };
  let stage = null;
  let time = 0, nextFrame = 0;
  const frames = new Map();

  function rect(x, y, w, h) { return { x, y, left: x, top: y, width: w, height: h, right: x + w, bottom: y + h }; }

  class El {
    constructor(tag) {
      this.tagName = (tag || 'div').toUpperCase();
      this.children = [];
      this.parentElement = null;
      this.dataset = {};
      this.style = { setProperty() {}, removeProperty() {} };
      this.classList = {
        _s: new Set(),
        add(...cs) { cs.forEach(c => this._s.add(c)); },
        remove(...cs) { cs.forEach(c => this._s.delete(c)); },
        contains(c) { return this._s.has(c); },
        toggle(c, on) { if (on === undefined) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); } else if (on) this._s.add(c); else this._s.delete(c); }
      };
      this._listeners = {};
      this._rect = rect(0, 0, 0, 0);
      this.textContent = '';
      this.hidden = false;
      this.isConnected = true;
      this.width = 1;
      this.height = 1;
      this.naturalWidth = 0;
      this.naturalHeight = 0;
      /* className 与 classList 保持同步(真实 DOM 就是这样) */
      const self = this;
      Object.defineProperty(this, 'className', {
        configurable: true,
        get() { return [...self.classList._s].join(' '); },
        set(v) { self.classList._s = new Set(String(v).split(/\s+/).filter(Boolean)); }
      });
    }
    getContext(kind) {
      if (kind === 'webgl') {
        const self = this;
        let w = 1, h = 1;
        Object.defineProperties(this, {
          width: { configurable: true, get: () => w, set: v => { w = v; metrics.resizes++; } },
          height: { configurable: true, get: () => h, set: v => { h = v; metrics.resizes++; } }
        });
        stage = this;
        return gl;
      }
      return twoD(this);
    }
    appendChild(c) { c.parentElement = this; this.children.push(c); return c; }
    prepend(c) { c.parentElement = this; this.children.unshift(c); return c; }
    removeChild(c) { this.children = this.children.filter(x => x !== c); c.parentElement = null; return c; }
    remove() { if (this.parentElement) this.parentElement.removeChild(this); }
    setAttribute(k, v) { if (k === 'hidden') this.hidden = v !== 'false' && v !== null; }
    getAttribute(k) { return null; }
    addEventListener(t, fn) { this._listeners[t] = fn; }
    removeEventListener() {}
    closest(sel) {
      let n = this;
      while (n) { if (n.matches(sel)) return n; n = n.parentElement; }
      return null;
    }
    matches(sel) {
      /* 支持 "tag" / ".cls" / "tag.cls" 三种形式 */
      const parts = sel.split('.');
      const tag = parts[0];
      if (tag && tag !== '*' && this.tagName !== tag.toUpperCase()) return false;
      const cls = parts.slice(1).join('.');
      if (!cls) return true;
      return cls.split('.').every(c => this.classList.contains(c));
    }
    querySelectorAll(sel) {
      const out = [];
      const walk = n => {
        for (const c of n.children) {
          if (c.matches(sel)) out.push(c);
          walk(c);
        }
      };
      walk(this);
      return out;
    }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
    getBoundingClientRect() { return this._rect; }
    getClientRects() { return [this._rect]; }
  }

  const document = {
    documentElement: new El('html'),
    body: new El('body'),
    visibilityState: 'visible',
    hidden: false,
    createElement: t => new El(t),
    addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
    getElementById(id) { return id === 'glass-canvas' ? glassCanvas : null; },
    querySelectorAll(sel) { return document.body.querySelectorAll(sel); },
    querySelector(sel) { return document.body.querySelector(sel); }
  };
  const glassCanvas = new El('canvas');

  function twoD(canvas) {
    const grad = { addColorStop() {} };
    return {
      save() {}, restore() {}, clearRect() {}, fillRect() {}, scale() {}, fillText() {},
      beginPath() {}, rect() {}, clip() {},
      filter: 'none',
      fillStyle: '',
      createLinearGradient: () => grad,
      createRadialGradient: () => grad,
      drawImage(src, ...args) {
        if (src === stage && args.length === 8) metrics.copies++;
      },
      getImageData: () => ({ data: new Uint8ClampedArray(64) })
    };
  }

  const gl = {
    VERTEX_SHADER: 1, FRAGMENT_SHADER: 2, COMPILE_STATUS: 3, LINK_STATUS: 4,
    ARRAY_BUFFER: 5, STATIC_DRAW: 6, FLOAT: 7, UNPACK_FLIP_Y_WEBGL: 8,
    TEXTURE_2D: 9, TEXTURE_MIN_FILTER: 10, TEXTURE_MAG_FILTER: 11,
    TEXTURE_WRAP_S: 12, TEXTURE_WRAP_T: 13, LINEAR: 14, CLAMP_TO_EDGE: 15,
    RGBA: 16, UNSIGNED_BYTE: 17, TEXTURE0: 18, TRIANGLES: 19,
    createShader: () => ({}), shaderSource() {}, compileShader() {},
    getShaderParameter: () => true, deleteShader() {},
    createProgram: () => ({}), attachShader() {}, linkProgram() {},
    getProgramParameter: () => true, useProgram() {},
    createBuffer: () => ({}), bindBuffer() {}, bufferData() {},
    getAttribLocation: () => 0, enableVertexAttribArray() {}, vertexAttribPointer() {},
    pixelStorei() {}, getUniformLocation: () => 0,
    uniform1i() {}, uniform1f() {}, uniform2f() {}, uniform4f() {},
    activeTexture() {}, texParameteri() {}, viewport() {},
    createTexture() { metrics.creates++; return {}; },
    bindTexture() {}, deleteTexture() {},
    texImage2D() { metrics.uploads++; },
    texSubImage2D() { metrics.uploads++; },
    drawArrays() { metrics.draws++; }
  };

  const bindings = {
    console, performance: { now: () => time },
    innerWidth: 393, innerHeight: 852, devicePixelRatio: 2, scrollY: 0,
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    requestAnimationFrame: fn => { const id = ++nextFrame; frames.set(id, fn); return id; },
    cancelAnimationFrame: id => frames.delete(id),
    ResizeObserver: class { observe() {} unobserve() {} },
    MutationObserver: class { observe() {} disconnect() {} },
    NodeFilter: { SHOW_TEXT: 4 },
    CustomEvent: class { constructor(t, o) { this.type = t; this.detail = o && o.detail; } },
    Event: class { constructor(t) { this.type = t; } },
    getComputedStyle: () => ({ color: '#111', fontSize: '14px', fontFamily: 'sans-serif', fontWeight: '500', visibility: 'visible', display: 'block' }),
    localStorage: { _d: {}, getItem(k) { return this._d[k] ?? null; }, setItem(k, v) { this._d[k] = v; } }
  };
  const window = {
    document, Element: El, addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
    removeEventListener() {},
    dispatchEvent(ev) {
      const fns = listeners[ev && ev.type] || [];
      fns.slice().forEach(fn => fn(ev));
      return true;
    },
    matchMedia: bindings.matchMedia, requestAnimationFrame: bindings.requestAnimationFrame,
    cancelAnimationFrame: bindings.cancelAnimationFrame,
    ResizeObserver: bindings.ResizeObserver, MutationObserver: bindings.MutationObserver,
    devicePixelRatio: 2, innerWidth: 393, innerHeight: 852,
    performance: bindings.performance, localStorage: bindings.localStorage,
    getComputedStyle: bindings.getComputedStyle,
    CustomEvent: bindings.CustomEvent, Event: bindings.Event,
    NodeFilter: bindings.NodeFilter
  };
  window.window = window;
  window.self = window;
  window.globalThis = window;
  for (const [k, v] of Object.entries(bindings)) if (window[k] === undefined) window[k] = v;

  /* 造 DOM: 一个 active page + 3 个玻璃面, 另一个隐藏 page */
  const page = new El('section');
  page.classList.add('page', 'active');
  const glassEls = [];
  for (let i = 0; i < 3; i++) {
    const g = new El('article');
    g.classList.add('g');
    g.dataset.role = 'panel';
    g.dataset.radius = '22';
    g._rect = rect(16, 100 + i * 120, 361, 100);
    page.appendChild(g);
    glassEls.push(g);
  }
  const hiddenPage = new El('section');
  hiddenPage.classList.add('page');
  const hiddenGlass = new El('article');
  hiddenGlass.classList.add('g');
  hiddenGlass.dataset.role = 'panel';
  hiddenGlass._rect = rect(16, 100, 361, 100);
  hiddenPage.appendChild(hiddenGlass);
  document.body.appendChild(page);
  document.body.appendChild(hiddenPage);
  document.body.appendChild(glassCanvas);

  const context = vm.createContext(window);

  function step(count = 1) {
    for (let n = 0; n < count; n++) {
      time += 16;
      const cbs = [...frames.values()];
      frames.clear();
      cbs.forEach(fn => fn(time));
    }
  }
  return {
    window, document, frames, metrics, step, glassEls, hiddenGlass, page, hiddenPage,
    run(code, name) { vm.runInContext(code, context, { filename: name }); }
  };
}

async function main() {
  const js = fs.readFileSync(path.join(WEB, 'glass-liquid.js'), 'utf8');

  const h = makeHost();
  h.run(js, 'glass-liquid.js');

  const g = h.window.FallingGlass;
  assert(g, '引擎未挂载 window.FallingGlass');
  assert.equal(g.runtime(), 'WebGL', '引擎应报告 WebGL');

  h.step(4);
  const cold = { ...h.metrics };
  if (!cold.draws) {
    console.log('DEBUG stats=', JSON.stringify(g.stats()));
    console.log('DEBUG visible=', h.glassEls.map(e => JSON.stringify(e.getBoundingClientRect()) + ' ready=' + e.classList.contains('glass-ready')).join(' | '));
    console.log('DEBUG hidden=', JSON.stringify(h.hiddenGlass.getBoundingClientRect()));
  }
  assert(cold.draws > 0, '首帧必须有绘制');
  assert.equal(cold.draws, h.glassEls.length,
    `首帧应只画可见页面的玻璃面(${h.glassEls.length}), 实际 ${cold.draws}`);
  assert(h.glassEls.every(e => e.classList.contains('glass-ready')),
    '可见玻璃面应标记 glass-ready');
  assert(!h.hiddenGlass.classList.contains('glass-ready'),
    '隐藏页面的玻璃面不应被绘制');
  console.log(`PASS 首帧: 画 ${cold.draws} 个面, 传 ${cold.uploads} 次纹理, 隐藏页已跳过`);

  /* 静止时零重绘
     invalidate(720) 打开 720ms 的动画窗口, 窗口内每帧都会走 paint,
     但因为 renderKey 没变, 不会真的重画任何东西。
     窗口结束后引擎必须停止排帧(否则就是常驻 60fps 空转)。 */
  g.invalidate(720);
  h.step(30);
  assert.equal(h.metrics.draws, cold.draws, '动画窗口内的 tick 不应额外绘制');
  assert.equal(h.metrics.uploads, cold.uploads, '动画窗口内不应重传纹理');
  assert.equal(h.metrics.resizes, cold.resizes, '动画窗口内不应重设 stage 尺寸');
  h.step(40); // 越过 720ms 窗口
  assert.equal(h.frames.size, 0, '动画窗口结束后不应继续排帧');
  assert.equal(h.metrics.draws, cold.draws, '全程零额外绘制');
  console.log('PASS 静止: 零额外绘制 / 零纹理上传 / 零 stage 变更 / 窗口结束即停帧');

  /* 切页: 新页面可见, 旧页面释放 */
  h.page.classList.remove('active');
  h.hiddenPage.classList.add('active');
  h.window.dispatchEvent(new h.window.CustomEvent('nova:page', { detail: { animate: false } }));
  h.step(4);
  const afterSwitch = h.metrics.draws;
  assert(afterSwitch > cold.draws, '切页后必须重绘新页面的玻璃面');
  assert(h.hiddenGlass.classList.contains('glass-ready'), '新页面的玻璃面应被绘制');
  assert(!h.glassEls.some(e => e.classList.contains('glass-ready')),
    '旧页面的玻璃面应被释放');
  console.log(`PASS 切页: 新面已绘制(${afterSwitch - cold.draws} 次), 旧面已释放`);

  /* 关闭玻璃: canvas 摘掉, 停止绘制 */
  const before = h.metrics.draws;
  g.setEnabled(false);
  h.step(6);
  assert.equal(h.metrics.draws, before, '关闭玻璃后不应再绘制');
  assert.equal(h.document.querySelectorAll('canvas.glass-surface').length, 0,
    '关闭玻璃后 canvas 应全部摘除');
  console.log('PASS 关闭: canvas 已摘除, 零绘制');

  /* 再打开: 重新登记并绘制 */
  g.setEnabled(true);
  h.step(4);
  assert(h.metrics.draws > before, '重新打开后应恢复绘制');
  assert(h.document.querySelectorAll('canvas.glass-surface').length > 0,
    '重新打开后 canvas 应重新插入');
  console.log('PASS 重开: 玻璃面已重新登记并渲染');

  /* 纹理缓存上限 */
  for (let i = 0; i < 40; i++) {
    g.configure({ cardBlur: 4 + (i % 20) });
    h.step(1);
  }
  assert(g.stats().textureBytes <= 24 * 1024 * 1024,
    '纹理缓存应遵守字节上限');
  console.log(`PASS 纹理缓存: ${(g.stats().textureBytes / 1048576).toFixed(1)}MB / 24MB 上限`);

  console.log('\n全部通过 [OK]');
}

main().catch(e => { console.error(e); process.exitCode = 1; });
