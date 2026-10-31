/* ============================================================
   Falling-MT6991 · 液态玻璃引擎 (WebGL / AGSL 镜面折射)
   ------------------------------------------------------------
   移植自 NovaSched-Zen-Edition 的 assets/liquid-glass.js
     原作者: ZenJooo. "WebGL adapter for Kyant Backdrop's AGSL lens"
     许可: Apache-2.0
     原实现参考: SleepDown beta5 (5ed891bc4563d9a0dd56edb63902bcfaf5d88a2c)
   思路与 NovaSched 完全一致:
     - 整个界面只有「一块玻璃」: 所有 .g 元素共用一个 WebGL stage,
       每个玻璃面把自己的折射结果写进自己的一张小 canvas。
     - 折射用 SDF 圆角矩形 + feDisplacement 式偏移 + 光谱色散,
       背景是墙面(source)纹理。
     - 静止时零重绘: 每块玻璃记住自己的 renderKey, 没变就不画。
   在它之上为本项目做的改动:
     - 背景不是外部壁纸图片, 而是程序化生成的渐变壁纸 canvas
       (配色与 theme.css 的 --fill/--accent 体系一致), 免二进制资源。
     - 指针跟随高光全部去掉: 原实现靠逐元素 getBoundingClientRect +
       写 CSS 变量, 在 30+ 玻璃面的页面上是 layout thrashing,
       触摸滚动时必卡。这里的高光由 shader 的边缘 rim 光提供。
     - 每块玻璃挂 ResizeObserver: 内容高度变化时精确重绘。
     - 提供 setEnabled(): 用户关掉「液态玻璃」时彻底摘掉 canvas,
       退回 CSS 半透明(不跑 WebGL, 不占显存)。
   对外 API:
     window.FallingGlass = {
       setEnabled(on), isEnabled(), setTheme(light|dark),
       setLevel(0..100), refresh(), invalidate(ms), stats(), runtime()
     }
   同时挂 window.NovaGlass 别名, 保持与 NovaSched 同名 API。
   ============================================================ */
(() => {
  "use strict";
  if (window.FallingGlass) return;

  const background = document.getElementById("glass-canvas");
  const reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)");
  const stage = document.createElement("canvas");
  const source = document.createElement("canvas");
  const scene = document.createElement("canvas");
  const lensSource = document.createElement("canvas");
  const textSource = document.createElement("canvas");
  const textureScratch = document.createElement("canvas");
  const textContext = textSource.getContext("2d");
  const textureContext = textureScratch.getContext("2d");
  const lensContext = lensSource.getContext("2d");
  const sourceContext = source.getContext("2d");
  const sceneContext = scene.getContext("2d");
  const backgroundContext = background ? background.getContext("2d") : null;
  const gl = stage.getContext("webgl", {
    alpha: true, antialias: false, premultipliedAlpha: false,
    preserveDrawingBuffer: true, powerPreference: "low-power"
  });
  let available = !!(gl && gl.createShader && sourceContext && sourceContext.drawImage && backgroundContext && backgroundContext.drawImage);

  let theme = "light";
  let enabled = true;
  let wall = { blur: 0, brightness: 1, centerX: .5, centerY: .5, scale: 1 };
  let settings = {
    level: 50, cardBlur: 24, cardAlpha: 73, cardRadius: 22,
    chromeBlur: 100, dispersion: true, material: true,
    colorMode: "colorful", cardColor: "#8ab4f8",
    /* 卡片配色: 冷暖交替的低饱和玻璃色, 避免相邻两行撞色看不清边界 */
    palette: ["#8ab4f8", "#7bd88f", "#f0a0b8", "#a8b6f0", "#e8c47a", "#79c8d8"]
  };
  let width = 0, height = 0, ratio = 1, sourceEpoch = 0, sceneEpoch = 0;
  let sourceDirty = true, sceneDirty = true, textDirty = true;
  let frame = 0, until = 0, hidden = false, materialRevision = 0, nextSurfaceId = 0;
  let settingsKey = JSON.stringify(settings);
  const SAMPLE_PIXELS = 600000;
  const TEXTURE_BYTES = 24 * 1024 * 1024;
  const counters = { frames: 0, draws: 0, stageResizes: 0, textureUploads: 0, lensRecords: 0, sceneRecords: 0, textRecords: 0, glyphReads: 0 };
  /* 最后一次渲染异常: 静默降级会让人以为「玻璃没生效」, 必须留痕 */
  let lastError = "";
  let program, buffer;
  const surfaces = new Map(), textures = new Map();

  const vertex = `attribute vec2 position; varying vec2 uv; void main(){uv=position*.5+.5;gl_Position=vec4(position,0.,1.);}`;
  const fragment = `
precision highp float;
varying vec2 uv;
uniform sampler2D content;
uniform vec2 screen;
uniform vec4 rect;
uniform float radius;
uniform vec4 material;
uniform vec4 tint;
uniform float gradientTint;
uniform float highlightAlpha;
float sdRoundedRect(vec2 p, vec2 halfSize, float r){
  vec2 cornerCoord=abs(p)-(halfSize-vec2(r));
  return length(max(cornerCoord,0.))-r+min(max(cornerCoord.x,cornerCoord.y),0.);
}
vec2 gradSdRoundedRect(vec2 p,vec2 halfSize,float r){
  vec2 cornerCoord=abs(p)-(halfSize-vec2(r));
  if(cornerCoord.x>=0.||cornerCoord.y>=0.)return sign(p)*normalize(max(cornerCoord,0.)+vec2(.000001));
  float gradX=step(cornerCoord.y,cornerCoord.x);
  return sign(p)*vec2(gradX,1.-gradX);
}
float circleMap(float x){return 1.-sqrt(max(0.,1.-x*x));}
vec4 sampleContent(vec2 p){return texture2D(content,clamp(p/screen,vec2(.00001),vec2(.99999)));}
vec4 refractContent(vec2 coord,vec2 p,vec2 halfSize,float sd){
  float refractionHeight=material.x;
  if(refractionHeight<=0.||-sd>=refractionHeight)return sampleContent(rect.xy+coord);
  float d=circleMap(1.-clamp(-min(sd,0.)/refractionHeight,0.,1.))*material.y;
  float gradRadius=min(radius*1.5,min(halfSize.x,halfSize.y));
  vec2 grad=normalize(gradSdRoundedRect(p,halfSize,gradRadius)+material.z*(p/max(length(p),.00001)));
  vec2 refractedCoord=rect.xy+coord+d*grad;
  float dispersionIntensity=material.w*((p.x*p.y)/max(halfSize.x*halfSize.y,.00001));
  vec2 dispersedCoord=d*grad*dispersionIntensity;
  if(material.w==0.)return sampleContent(refractedCoord);
  vec4 color=vec4(0.);
  vec4 red=sampleContent(refractedCoord+dispersedCoord);
  color.r+=red.r/3.5; color.a+=red.a/7.;
  vec4 orange=sampleContent(refractedCoord+dispersedCoord*(2./3.));
  color.r+=orange.r/3.5; color.g+=orange.g/7.; color.a+=orange.a/7.;
  vec4 yellow=sampleContent(refractedCoord+dispersedCoord*(1./3.));
  color.r+=yellow.r/3.5; color.g+=yellow.g/3.5; color.a+=yellow.a/7.;
  vec4 green=sampleContent(refractedCoord);
  color.g+=green.g/3.5; color.a+=green.a/7.;
  vec4 cyan=sampleContent(refractedCoord-dispersedCoord*(1./3.));
  color.g+=cyan.g/3.5; color.b+=cyan.b/3.; color.a+=cyan.a/7.;
  vec4 blue=sampleContent(refractedCoord-dispersedCoord*(2./3.));
  color.b+=blue.b/3.; color.a+=blue.a/7.;
  vec4 purple=sampleContent(refractedCoord-dispersedCoord);
  color.r+=purple.r/7.; color.b+=purple.b/3.; color.a+=purple.a/7.;
  return color;
}
void main(){
  vec2 coord=vec2(uv.x,1.-uv.y)*rect.zw;
  vec2 halfSize=rect.zw*.5, p=coord-halfSize;
  float sd=sdRoundedRect(p,halfSize,radius);
  float coverage=1.-smoothstep(-.75,.5,sd);
  if(coverage==0.){gl_FragColor=vec4(0.);return;}
  vec4 c=refractContent(coord,p,halfSize,sd);
  float alpha=tint.a*(gradientTint>.5?mix(.22,1.,coord.y/max(rect.w,1.)):1.);
  c.rgb=mix(c.rgb,tint.rgb,alpha);
  vec2 grad=gradSdRoundedRect(p,halfSize,min(radius*1.5,min(halfSize.x,halfSize.y)));
  float directional=pow(abs(dot(grad,normalize(vec2(-1.,-1.)))),1.);
  float rim=(1.-smoothstep(0.,1.2,abs(sd)))*directional*highlightAlpha;
  c.rgb=mix(c.rgb,vec3(1.),rim);
  gl_FragColor=vec4(c.rgb,coverage);
}`;

  function compile(kind, code) {
    const shader = gl.createShader(kind);
    gl.shaderSource(shader, code);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) { gl.deleteShader(shader); throw new Error("Shader compile failed"); }
    return shader;
  }
  function initialize() {
    if (!available) return;
    try {
      const vs = compile(gl.VERTEX_SHADER, vertex), fs = compile(gl.FRAGMENT_SHADER, fragment);
      program = gl.createProgram(); gl.attachShader(program, vs); gl.attachShader(program, fs); gl.linkProgram(program);
      gl.deleteShader(vs); gl.deleteShader(fs);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error("Shader link failed");
      gl.useProgram(program);
      buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
      const location = gl.getAttribLocation(program, "position");
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, 2, gl.FLOAT, false, 0, 0);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      document.documentElement.dataset.renderer = "webgl-kyant-port";
    } catch (_) { fallback(); }
  }
  function fallback() {
    available = false;
    document.body.classList.add("glass-flat");
    document.documentElement.dataset.renderer = "css-backdrop";
    if (backgroundContext && backgroundContext.drawImage && background) background.style.display = "none";
    until = 0;
    for (const [element, record] of surfaces) {
      element.classList.remove("glass-ready");
      record.canvas.style.display = "none";
      record.renderKey = "";
    }
  }
  function motionAllowed() {
    return available && !(reduced && reduced.matches) && document.documentElement.dataset.motion !== "reduce";
  }
  function invalidate(duration = 0) {
    if (hidden || !enabled) return;
    if (motionAllowed()) until = Math.max(until, performance.now() + duration);
    else until = 0;
    if (!frame) frame = requestAnimationFrame(paint);
  }

  /* ---------- 尺寸 ---------- */
  function dimensions() {
    const nextWidth = Math.max(1, window.innerWidth || 360);
    const nextHeight = Math.max(1, window.innerHeight || 800);
    if (nextWidth === width && nextHeight === height) return;
    width = nextWidth; height = nextHeight;
    ratio = Math.min(window.devicePixelRatio || 1, 2, Math.sqrt(1200000 / (width * height)));
    for (const canvas of [source, scene, lensSource, textSource, background]) {
      if (!canvas) continue;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
    }
    sourceDirty = sceneDirty = textDirty = true;
  }

  /* ---------- 渐变壁纸(替代外部图片) ----------
     配色与 theme.css 的浅色/深色体系一致, 画在离屏 canvas 上,
     既当显示背景(#glass-canvas), 也当折射源(source)。 */
  function buildWallpaper(themeName) {
    const W = 1080, H = 1920;
    const c = document.createElement("canvas");
    c.width = W; c.height = H;
    const g = c.getContext("2d");
    if (!g) return null;
    const dark = themeName === "dark";
    const base = g.createLinearGradient(W * .18, 0, W * .82, H);
    if (dark) {
      base.addColorStop(0, "#0d1015");
      base.addColorStop(.5, "#121722");
      base.addColorStop(1, "#0e131c");
    } else {
      base.addColorStop(0, "#e9eef5");
      base.addColorStop(.48, "#dfe8f4");
      base.addColorStop(1, "#e8eef6");
    }
    g.fillStyle = base;
    g.fillRect(0, 0, W, H);
    const blobs = dark
      ? [["rgba(10,132,255,.26)", .18, .12, .58, .44], ["rgba(120,60,200,.20)", .84, .22, .52, .40],
         ["rgba(30,110,60,.18)", .72, .88, .64, .50], ["rgba(160,90,20,.14)", .12, .78, .46, .38]]
      : [["rgba(10,132,255,.30)", .18, .12, .58, .44], ["rgba(191,90,242,.22)", .84, .22, .52, .40],
         ["rgba(48,209,88,.18)", .72, .88, .64, .50], ["rgba(255,159,10,.16)", .12, .78, .46, .38]];
    for (const [color, px, py, rx, ry] of blobs) {
      const rg = g.createRadialGradient(W * px, H * py, 0, W * px, H * py, Math.max(W * rx, H * ry));
      rg.addColorStop(0, color);
      rg.addColorStop(1, "transparent");
      g.fillStyle = rg;
      g.fillRect(0, 0, W, H);
    }
    return c;
  }
  let wallpaper = null;

  function wallTransform(w, h) {
    if (!wallpaper) return null;
    const iw = wallpaper.width, ih = wallpaper.height;
    if (!iw || !ih) return null;
    const scale = Math.max(w / iw, h / ih) * wall.scale;
    return {
      x: Math.max(w - iw * scale, Math.min(0, w / 2 - wall.centerX * iw * scale)),
      y: Math.max(h - ih * scale, Math.min(0, h / 2 - wall.centerY * ih * scale)),
      w: iw * scale, h: ih * scale
    };
  }
  function drawWallpaper(context, w, h) {
    if (!context || !context.fillRect) return;
    context.save();
    context.clearRect(0, 0, w, h);
    context.fillStyle = theme === "dark" ? "#121212" : "#f2f4f8";
    context.fillRect(0, 0, w, h);
    const transform = wallTransform(w, h);
    if (transform) {
      const px = wall.blur * .32 * (w / Math.max(1, width));
      context.filter = px > 0 ? `blur(${px}px) brightness(${wall.brightness})` : `brightness(${wall.brightness})`;
      const pad = Math.ceil(px * 3);
      if (pad) {
        context.drawImage(wallpaper, transform.x - pad, transform.y - pad, transform.w + pad * 2, transform.h + pad * 2);
      } else {
        context.drawImage(wallpaper, transform.x, transform.y, transform.w, transform.h);
      }
    }
    context.restore();
  }
  function rebuildSource() {
    if (!sourceDirty) return;
    drawWallpaper(sourceContext, source.width, source.height);
    if (backgroundContext && backgroundContext.drawImage) {
      backgroundContext.clearRect(0, 0, background.width, background.height);
      backgroundContext.drawImage(source, 0, 0);
    }
    sourceEpoch++;
    sourceDirty = false;
    sceneDirty = true;
  }

  function parseColor(value) {
    const match = /^#([\da-f]{6})$/i.exec(value || "");
    return match
      ? [parseInt(match[1].slice(0, 2), 16) / 255, parseInt(match[1].slice(2, 4), 16) / 255, parseInt(match[1].slice(4), 16) / 255]
      : [.54, .71, .97];
  }
  /* ---------- 角色材质表 ----------
     与 NovaSched 一致: role 决定折射强度/模糊/着色。 */
  function materialFor(element) {
    const role = (element.dataset && element.dataset.role) || "pill";
    const dark = theme === "dark";
    const neutral = dark ? [18 / 255, 18 / 255, 18 / 255] : [242 / 255, 244 / 255, 248 / 255];
    const strength = settings.level === 0 ? 0 : .5 + settings.level / 100;
    const data = {
      role, blur: 2.375 * settings.chromeBlur / 100, height: 11.4, amount: 22.8, depth: .1,
      dispersion: settings.dispersion ? .05 : 0, tint: neutral, alpha: dark ? .45 : .54,
      highlight: .055, gradient: 0
    };
    if (role === "course") {
      data.highlight = .045;
      data.blur = settings.cardBlur;
      data.height = 10 * strength;
      data.amount = 20 * strength;
      data.tint = parseColor(settings.colorMode === "colorful"
        ? settings.palette[(Number(element.dataset.colorIndex) || 0) % settings.palette.length]
        : settings.cardColor);
      data.alpha = settings.cardAlpha / 100 * .52;
      data.gradient = settings.colorMode === "gradient" ? 1 : 0;
      if (!settings.material) { data.height = data.amount = data.dispersion = 0; data.alpha = Math.max(.35, data.alpha); }
    } else if (role === "assistant") {
      data.blur = 16; data.height = 4; data.amount = 8; data.alpha = dark ? .60 : .80;
    } else if (role === "dock") {
      data.blur = 1.3 * settings.chromeBlur / 100; data.height = 10; data.amount = 40; data.depth = 0; data.highlight = .07;
    } else if (role === "lens") {
      data.blur = 0; data.height = 12; data.amount = 17; data.alpha = .1; data.depth = 0; data.highlight = .07;
    } else if (role === "popup" || role === "panel") {
      data.blur = 8; data.height = 12; data.amount = 24; data.alpha = role === "popup" ? .15 : .34;
    } else if (role === "dialog") {
      data.blur = 16; data.height = 4; data.amount = 8; data.alpha = dark ? .74 : .65;
    } else if (role === "settings") {
      data.blur = 16; data.height = 0; data.amount = 0; data.alpha = dark ? .8 : .73;
    } else if (role === "accent") {
      data.tint = parseColor("#0a84ff"); data.alpha = .58; data.height = 12; data.amount = 24;
    }
    if (settings.level === 0) data.height = data.amount = data.dispersion = 0;
    return data;
  }

  /* ---------- 玻璃面登记 ---------- */
  const surfaceObserver = typeof ResizeObserver === "function" ? new ResizeObserver(() => {
    sceneDirty = textDirty = true;
    invalidate();
  }) : null;

  function scan(root) {
    const scope = root || document;
    const found = [...scope.querySelectorAll(".g")];
    if (scope instanceof Element && scope.matches(".g")) found.unshift(scope);
    for (const element of found) {
      if (surfaces.has(element)) continue;
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      canvas.className = "glass-surface";
      canvas.setAttribute("aria-hidden", "true");
      const context = available ? canvas.getContext("2d") : null;
      if (available) element.prepend(canvas);
      const record = {
        id: ++nextSurfaceId, canvas, context, role: (element.dataset && element.dataset.role) || "pill",
        page: element.closest(".page"), dock: element.closest(".dock-wrap"),
        materialKey: "", materialDrawKey: "", renderKey: "", serial: 0, rect: null, radius: 0
      };
      surfaces.set(element, record);
      if (surfaceObserver) surfaceObserver.observe(element);
    }
    for (const [element, record] of surfaces) {
      if (element.isConnected) continue;
      record.canvas.remove();
      if (surfaceObserver) surfaceObserver.unobserve(element);
      surfaces.delete(element);
      removeTextures("lens:" + record.id);
    }
    invalidate();
  }
  function removeTextures(domain) {
    for (const [key, record] of textures) {
      if (record.domain !== domain) continue;
      gl && gl.deleteTexture && gl.deleteTexture(record.texture);
      textures.delete(key);
    }
  }
  function textureBytes() {
    let total = 0;
    for (const record of textures.values()) total += record.width * record.height * 4;
    return total;
  }
  function getTexture(base, blur, epoch, domain) {
    const key = domain + ":" + blur.toFixed(1);
    let record = textures.get(key);
    if (record && record.epoch === epoch) {
      textures.delete(key); textures.set(key, record);
      return record.texture;
    }
    const bitmap = typeof base === "function" ? base() : base;
    const scale = Math.min(1, Math.sqrt(SAMPLE_PIXELS / (bitmap.width * bitmap.height)));
    const w = Math.max(1, Math.floor(bitmap.width * scale));
    const h = Math.max(1, Math.floor(bitmap.height * scale));
    if (textureScratch.width !== w) textureScratch.width = w;
    if (textureScratch.height !== h) textureScratch.height = h;
    textureContext.clearRect(0, 0, w, h);
    textureContext.filter = blur > 0 ? `blur(${blur * w / width}px)` : "none";
    textureContext.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height, 0, 0, w, h);
    textureContext.filter = "none";
    if (!record) {
      record = { texture: gl.createTexture(), domain, width: 0, height: 0, epoch: null };
      gl.bindTexture(gl.TEXTURE_2D, record.texture);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    } else {
      gl.bindTexture(gl.TEXTURE_2D, record.texture);
    }
    if (record.width === w && record.height === h) {
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, textureScratch);
    } else {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, textureScratch);
    }
    counters.textureUploads++;
    record.width = w; record.height = h; record.epoch = epoch;
    textures.delete(key); textures.set(key, record);
    while (textures.size > 12 || textureBytes() > TEXTURE_BYTES) {
      const oldest = textures.keys().next().value;
      if (oldest === key && textures.size === 1) break;
      gl.deleteTexture(textures.get(oldest).texture);
      textures.delete(oldest);
    }
    return record.texture;
  }
  const locationCache = new Map();
  function uniform(name) {
    if (!locationCache.has(name)) locationCache.set(name, gl.getUniformLocation(program, name));
    return locationCache.get(name);
  }
  function releaseSurface(element, record) {
    record.rect = null;
    record.renderKey = "";
    if (record.canvas.width > 1 || record.canvas.height > 1) record.canvas.width = record.canvas.height = 1;
    if (element.classList.contains("glass-ready")) element.classList.remove("glass-ready");
  }
  function measure(element, record) {
    if (record.page && !record.page.classList.contains("active")) { releaseSurface(element, record); return null; }
    if (record.dock && record.dock.classList.contains("hidden")) { releaseSurface(element, record); return null; }
    if (element.closest("[hidden]")) { releaseSurface(element, record); return null; }
    const rect = element.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1 || rect.bottom <= 0 || rect.top >= height || rect.right <= 0 || rect.left >= width) {
      releaseSurface(element, record);
      return null;
    }
    record.rect = rect;
    return rect;
  }
  function ensureStage(w, h) {
    let resized = false;
    if (stage.width < w) { stage.width = Math.ceil(w / 64) * 64; resized = true; }
    if (stage.height < h) { stage.height = Math.ceil(h / 64) * 64; resized = true; }
    if (resized) counters.stageResizes++;
  }
  function drawSurface(element, record, rect, base, epoch, domain) {
    const src = base || source;
    const ep = epoch === undefined ? sourceEpoch : epoch;
    const dom = domain || "wall";
    const materialKey = [materialRevision, record.role, element.dataset.colorIndex, element.dataset.radius, element.dataset.state].join(":");
    if (record.materialKey !== materialKey) {
      record.material = materialFor(element);
      record.materialKey = materialKey;
      const drawKey = JSON.stringify(record.material);
      if (record.materialDrawKey !== drawKey) {
        record.materialDrawKey = drawKey;
        element.style.setProperty("--role-blur", record.material.blur + "px");
        element.style.setProperty("--surface-color", `rgba(${record.material.tint.map(x => Math.round(x * 255)).join(",")},${record.material.alpha})`);
      }
    }
    const material = record.material;
    const radius = material.role === "course"
      ? Math.min(settings.cardRadius, rect.width / 2, rect.height / 2)
      : Math.min(Number(element.dataset.radius) || 22, rect.width / 2, rect.height / 2);
    if (record.radius !== radius) { element.style.setProperty("--radius", radius + "px"); record.radius = radius; }
    if (!available || !record.context || !record.context.drawImage) return false;
    const key = [dom, ep, record.materialDrawKey, rect.left, rect.top, rect.width, rect.height, radius, ratio].join("|");
    if (record.renderKey === key && element.classList.contains("glass-ready")) return false;
    const w = Math.max(1, Math.round(rect.width * ratio)), h = Math.max(1, Math.round(rect.height * ratio));
    ensureStage(w, h);
    gl.viewport(0, 0, w, h);
    gl.useProgram(program);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, getTexture(src, material.blur, ep, dom));
    gl.uniform1i(uniform("content"), 0);
    gl.uniform2f(uniform("screen"), width, height);
    gl.uniform4f(uniform("rect"), rect.left, rect.top, rect.width, rect.height);
    gl.uniform1f(uniform("radius"), radius);
    gl.uniform4f(uniform("material"), material.height, material.amount, material.depth, material.dispersion);
    gl.uniform4f(uniform("tint"), material.tint[0], material.tint[1], material.tint[2], material.alpha);
    gl.uniform1f(uniform("gradientTint"), material.gradient);
    gl.uniform1f(uniform("highlightAlpha"), material.highlight);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    counters.draws++;
    if (record.canvas.width !== w) record.canvas.width = w;
    if (record.canvas.height !== h) record.canvas.height = h;
    record.context.clearRect(0, 0, w, h);
    record.context.drawImage(stage, 0, stage.height - h, w, h, 0, 0, w, h);
    record.renderKey = key;
    record.serial++;
    element.classList.add("glass-ready");
    return true;
  }
  function recordText() {
    if (!textDirty || !textContext || !textContext.drawImage) return;
    textContext.clearRect(0, 0, textSource.width, textSource.height);
    textDirty = false;
  }
  function recordScene(main) {
    if (!sceneDirty || !sceneContext || !sceneContext.drawImage) return;
    sceneContext.clearRect(0, 0, scene.width, scene.height);
    sceneContext.drawImage(source, 0, 0);
    recordText();
    sceneEpoch++;
    counters.sceneRecords++;
    sceneDirty = false;
  }
  function paint(time) {
    frame = 0;
    if (hidden || !enabled) return;
    counters.frames++;
    dimensions();
    rebuildSource();
    try {
      const main = [], lenses = [];
      for (const [element, record] of surfaces) {
        const rect = measure(element, record);
        if (!rect) continue;
        const group = record.role === "lens" ? lenses : main;
        group.push([element, record, rect]);
      }
      let geometryChanged = false;
      for (const [element, record, rect] of main) {
        const geometry = [rect.left, rect.top, rect.width, rect.height].join(":");
        if (record.geometry !== geometry) { geometryChanged = true; record.geometry = geometry; }
        if (drawSurface(element, record, rect)) sceneDirty = true;
      }
      if (geometryChanged) textDirty = true;
      for (const [element, record, rect] of lenses) {
        const parent = surfaces.get(element.parentElement);
        if (!available || !parent || !parent.rect || !lensContext || !lensContext.drawImage) {
          drawSurface(element, record, rect);
          continue;
        }
        const epoch = sourceEpoch + ":" + parent.serial;
        const base = () => {
          lensContext.clearRect(0, 0, lensSource.width, lensSource.height);
          lensContext.drawImage(source, 0, 0);
          const r = parent.rect;
          lensContext.drawImage(parent.canvas, r.left * ratio, r.top * ratio, r.width * ratio, r.height * ratio);
          counters.lensRecords++;
          return lensSource;
        };
        if (drawSurface(element, record, rect, base, epoch, "lens:" + parent.id)) sceneDirty = true;
      }
      if (available) recordScene(main.concat(lenses));
    } catch (err) {
      lastError = (err && err.message) || String(err);
      fallback();
    }
    if (time < until && motionAllowed()) invalidate();
  }

  /* ---------- 对外控制 ---------- */
  function setTheme(value) {
    const next = value === "dark" ? "dark" : "light";
    if (theme === next) return;
    theme = next;
    wallpaper = buildWallpaper(theme);
    sourceDirty = true;
    sceneDirty = textDirty = true;
    materialRevision++;
    invalidate();
  }
  function setLevel(value) {
    const next = Math.max(0, Math.min(100, Number(value) || 0));
    if (settings.level === next) return;
    settings.level = next;
    settingsKey = JSON.stringify(settings);
    materialRevision++;
    sceneDirty = true;
    invalidate();
  }
  function setWallOptions(options) {
    if (Object.entries(options).every(([k, v]) => wall[k] === v)) return;
    wall = { ...wall, ...options };
    wall.blur = Math.max(0, Math.min(100, Number(wall.blur) || 0));
    wall.brightness = Math.max(.35, Math.min(1, Number(wall.brightness) || 1));
    wall.scale = Math.max(1, Math.min(4, Number(wall.scale) || 1));
    sourceDirty = true;
    invalidate();
  }
  function configure(options) {
    const next = { ...settings, ...options }, key = JSON.stringify(next);
    if (settingsKey === key) return;
    settings = next;
    settingsKey = key;
    materialRevision++;
    sceneDirty = true;
    invalidate();
  }
  function setEnabled(on) {
    const next = !!on;
    if (enabled === next) return;
    enabled = next;
    document.documentElement.setAttribute("data-glass", enabled ? "on" : "off");
    try { localStorage.setItem("falling.glass.v3", enabled ? "on" : "off"); } catch (e) {}
    if (!enabled) {
      for (const [element, record] of surfaces) {
        record.canvas.remove();
        element.classList.remove("glass-ready");
        record.renderKey = "";
      }
      surfaces.clear();
      if (surfaceObserver) { /* 观察对象已随 surfaces 清空 */ }
      document.body.classList.add("glass-flat");
      return;
    }
    document.body.classList.remove("glass-flat");
    sourceDirty = sceneDirty = textDirty = true;
    scan();
  }

  /* ---------- 启动 ---------- */
  wallpaper = buildWallpaper(theme);
  initialize();
  if (!available) fallback();
  scan();

  const resizeObserver = typeof ResizeObserver === "function" ? new ResizeObserver(() => {
    sceneDirty = textDirty = true;
    invalidate();
  }) : null;
  if (resizeObserver) resizeObserver.observe(document.documentElement);

  const mutationObserver = typeof MutationObserver === "function" ? new MutationObserver(records => {
    let structural = false;
    for (const record of records) {
      if (record.target instanceof Element && record.target.matches("canvas")) continue;
      if (record.type === "childList") {
        const nodes = [...record.addedNodes, ...record.removedNodes];
        if (!nodes.length) continue;
        if (nodes.every(node => node instanceof Element && node.matches("canvas.glass-surface"))) continue;
        if (nodes.some(node => node instanceof Element && (node.matches(".g") || node.querySelector(".g")))) structural = true;
      }
    }
    if (!structural) return;
    scan();
  }) : null;
  if (mutationObserver && document.body) {
    mutationObserver.observe(document.body, { childList: true, subtree: true });
  }

  for (const name of ["resize", "orientationchange", "falling:viewport"]) {
    window.addEventListener(name, () => {
      sourceDirty = sceneDirty = textDirty = true;
      invalidate(500);
    }, { passive: true });
  }
  // 内容区滚动: 玻璃面跟着内容走, 必须重画
  document.addEventListener("scroll", () => {
    sceneDirty = textDirty = true;
    invalidate();
  }, { passive: true, capture: true });
  window.addEventListener("scroll", () => {
    sceneDirty = textDirty = true;
    invalidate();
  }, { passive: true });
  window.addEventListener("nova:page", event => {
    scan();
    sceneDirty = textDirty = true;
    invalidate(event && event.detail && event.detail.animate ? 560 : 0);
  });
  document.addEventListener("visibilitychange", () => {
    hidden = document.visibilityState === "hidden";
    if (hidden) { cancelAnimationFrame(frame); frame = 0; until = 0; }
    else { sceneDirty = textDirty = true; invalidate(); }
  });
  if (stage.addEventListener) {
    stage.addEventListener("webglcontextlost", event => { event.preventDefault(); fallback(); });
    stage.addEventListener("webglcontextrestored", () => {
      available = !!gl;
      locationCache.clear();
      textures.clear();
      initialize();
      if (available) {
        document.body.classList.remove("glass-flat");
        materialRevision++;
        for (const [element, record] of surfaces) {
          if (!record.canvas.isConnected) element.prepend(record.canvas);
          record.context = record.canvas.getContext("2d");
          record.canvas.style.display = "";
          record.renderKey = "";
        }
        sourceDirty = sceneDirty = textDirty = true;
        invalidate();
      }
    });
  }

  const api = {
    scan, refresh: () => { sceneDirty = textDirty = true; invalidate(); }, invalidate,
    setTheme, setLevel, setWallOptions, configure, setEnabled,
    isEnabled: () => enabled,
    runtime: () => (available ? "WebGL" : "CSS"),
    materials: materialFor,
    stats: () => ({ ...counters, surfaces: surfaces.size, textureBytes: textureBytes(), lastError }),
    reference: "kyant/backdrop · SleepDown 1.2.7_beta5 (via NovaSched-Zen-Edition)"
  };
  window.FallingGlass = api;
  window.NovaGlass = api;
})();
