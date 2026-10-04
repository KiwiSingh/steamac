// Scroll choreography for the landing page: the launcher window tilts into an isometric view,
// the six layers separate along Z, then each layer slides out in turn while its article shows.
(function () {
  "use strict";

  const REPO = "fxgl/steamac";
  const root = document.documentElement;

  // ---------- Language ----------
  function setLang(lang) {
    root.dataset.lang = lang;
    root.lang = lang;
    try { localStorage.setItem("lang", lang); } catch (e) { /* private mode */ }
    window.dispatchEvent(new Event("langchange"));   // hero copy height changed
  }
  document.querySelectorAll("[data-set-lang]").forEach((b) =>
    b.addEventListener("click", () => setLang(b.dataset.setLang)));

  // ---------- Latest release: direct asset link + version, else the releases page stays ----------
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : null))
    .then((rel) => {
      if (!rel) return;
      const asset = (rel.assets || []).find((a) => /\.(dmg|zip)$/i.test(a.name));
      document.querySelectorAll("[data-dl]").forEach((a) => { if (asset) a.href = asset.browser_download_url; });
      document.querySelectorAll("[data-ver]").forEach((s) => { s.textContent = rel.tag_name || ""; });
    })
    .catch(() => {});

  // ---------- Settings showcase: tab list and the screenshot's toolbar switch the shown tab ----------
  const settingsBox = document.getElementById("settings");
  if (settingsBox) {
    const tabButtons = [...settingsBox.querySelectorAll(".settings-tabs [data-tab]")];
    const shots = [...settingsBox.querySelectorAll(".settings-window img")];
    const names = tabButtons.map((b) => b.dataset.tab);
    let current = names[0], timer = 0, touched = false;
    const show = (name) => {
      current = name;
      tabButtons.forEach((b) => b.setAttribute("aria-selected", String(b.dataset.tab === name)));
      shots.forEach((img) => img.classList.toggle("show", img.dataset.tab === name));
    };
    const pick = (name) => { touched = true; clearInterval(timer); show(name); };
    settingsBox.querySelectorAll("[data-tab]:not(img)").forEach((el) =>
      el.addEventListener("click", () => pick(el.dataset.tab)));
    // Cycle through the tabs while the section is on screen, until the visitor picks one.
    if ("IntersectionObserver" in window && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      new IntersectionObserver(([entry]) => {
        clearInterval(timer);
        if (entry.isIntersecting && !touched) {
          timer = setInterval(() => show(names[(names.indexOf(current) + 1) % names.length]), 4500);
        }
      }, { threshold: 0.5 }).observe(settingsBox.querySelector(".settings-grid"));
    }
  }

  // ---------- Scene ----------
  const scene = document.getElementById("scene");
  const rig = scene.querySelector(".rig");
  const layers = [...scene.querySelectorAll(".layer")];
  const infos = new Map([...scene.querySelectorAll(".info")].map((el) => [Number(el.dataset.i), el]));
  const railButtons = [...scene.querySelectorAll(".rail button")];
  const rail = scene.querySelector(".rail");
  const hero = scene.querySelector(".hero-copy");
  const hint = scene.querySelector(".scroll-hint");
  const video = scene.querySelector(".screen-video");
  const N = layers.length;

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (reduced.matches) {
    root.classList.add("static");
    if (video) { video.pause(); video.removeAttribute("autoplay"); video.querySelector("source")?.remove(); video.load(); }
    return;
  }

  // Timeline, in scene progress 0..1: explode, a short hold on the whole stack, then one
  // segment per layer. Inside a segment the focus holds on the layer, then glides to the next.
  const EXPLODE_FROM = 0.02, EXPLODE_TO = 0.15;
  const FOCUS_FROM = 0.21, FOCUS_TO = 0.99;
  const PER = (FOCUS_TO - FOCUS_FROM) / N;
  const focusCenter = (i) => FOCUS_FROM + PER * (i + 0.5);

  const clamp01 = (v) => Math.min(1, Math.max(0, v));
  const lerp = (a, b, k) => a + (b - a) * k;
  const easeInOut = (k) => (k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);
  const smooth = (k) => k * k * (3 - 2 * k);

  function progress() {
    const r = scene.getBoundingClientRect();
    const span = scene.offsetHeight - window.innerHeight;
    return span > 0 ? clamp01(-r.top / span) : 0;
  }

  let shown = null;
  function showInfo(i) {
    if (i === shown) return;
    if (shown !== null && infos.get(shown)) infos.get(shown).classList.remove("show");
    if (infos.get(i)) infos.get(i).classList.add("show");
    shown = i;
  }

  // Continuous focus position: integer = resting on that layer, fractional = moving between.
  function focusPosition(t) {
    const raw = (t - FOCUS_FROM) / PER - 0.5;
    const n = Math.floor(raw), frac = raw - n;
    const phi = n + smooth(clamp01((frac - 0.35) / 0.3));
    return { phi: Math.min(N - 1, Math.max(0, phi)), q: smooth(clamp01((raw + 0.5) / 0.3)) };
  }

  function render(t) {
    const vw = window.innerWidth, vh = window.innerHeight;
    const wide = vw > 900;
    const W = rig.offsetWidth;
    const e = easeInOut(clamp01((t - EXPLODE_FROM) / (EXPLODE_TO - EXPLODE_FROM)));
    const { phi, q } = focusPosition(t);

    // Gaps between layer i-1 and i. Flat hero: 40px, so raised chips stay hidden behind the screen.
    // Exploded: even spacing. Focused: compact stack, with a wide opening above the focused layer
    // so it can be seen whole from the tilted viewpoint.
    const z = [0];
    for (let i = 1; i < N; i++) {
      const d = clamp01(1 - Math.abs(phi - i));
      const spread = lerp(W * 0.13, W * 0.06 + W * 0.5 * smooth(d), q);
      z.push(z[i - 1] - lerp(40, spread, e));
    }
    const lo = Math.floor(phi), hi = Math.min(N - 1, lo + 1);
    const zFocus = lerp(z[lo], z[hi], phi - lo);
    const zCenter = e * lerp(z[N - 1] / 2, zFocus, q);

    // Rig: from the flat hero window (low on screen, peeking) to the tilted stack that follows focus.
    // Position and scale lead the rotation so the window rises into view before it tips over.
    const p = easeInOut(clamp01((t - EXPLODE_FROM) / ((EXPLODE_TO - EXPLODE_FROM) * 0.7)));
    // Flat hero: the window's top sits just under the hero copy, but always shows at least 40% of it.
    const s0 = wide ? 0.94 : 1, H = rig.offsetHeight;
    const top = Math.min(hero.offsetTop + hero.offsetHeight + 28, vh - 0.4 * H * s0);
    const heroY = top - vh / 2 + (H * s0) / 2;
    const x = lerp(0, wide ? vw * 0.15 : 0, p);
    const y = lerp(heroY, wide ? vh * 0.09 : -vh * 0.08, p);
    const s = lerp(s0, wide ? 0.62 : 0.78, p);
    const rx = 56 * e, rz = -32 * e;
    rig.style.transform =
      `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0) rotateX(${rx.toFixed(2)}deg) rotateZ(${rz.toFixed(2)}deg) ` +
      `scale3d(${s.toFixed(4)}, ${s.toFixed(4)}, ${s.toFixed(4)}) translateZ(${(-zCenter).toFixed(1)}px)`;

    layers.forEach((layer, i) => {
      layer.style.transform = `translate3d(0, 0, ${(z[i] - i * 0.6).toFixed(1)}px)`;
      layer.style.visibility = i > 0 && e < 0.002 ? "hidden" : "";
    });

    const exploded = e > 0.6;
    const active = exploded && q > 0.5 ? Math.round(phi) : -1;
    layers.forEach((layer, i) => {
      layer.classList.toggle("on", i === active);
      layer.classList.toggle("off", active !== -1 && i !== active);
    });

    showInfo(exploded ? active : null);
    railButtons.forEach((b, i) => b.classList.toggle("on", i === active));
    rail.classList.toggle("show", exploded);

    const h = clamp01(t / 0.06);
    hero.style.opacity = String(1 - h);
    hero.style.transform = `translateY(${(-h * 60).toFixed(1)}px)`;
    hero.style.visibility = h >= 1 ? "hidden" : "visible";
    hint.style.opacity = String(1 - clamp01(t / 0.03));
  }

  // Ease toward the scroll position so wheel steps glide instead of snapping.
  let current = progress(), target = current, raf = 0;
  function tick() {
    current += (target - current) * 0.14;
    if (Math.abs(target - current) < 0.0004) current = target;
    render(current);
    raf = current === target ? 0 : requestAnimationFrame(tick);
  }
  function kick() {
    target = progress();
    if (!raf) raf = requestAnimationFrame(tick);
  }
  window.addEventListener("scroll", kick, { passive: true });
  const relayout = () => { target = current = progress(); render(current); };
  window.addEventListener("resize", relayout);
  window.addEventListener("langchange", relayout);
  render(current);

  // Rail: jump to a layer.
  railButtons.forEach((b) => b.addEventListener("click", () => {
    const i = Number(b.dataset.go);
    const span = scene.offsetHeight - window.innerHeight;
    window.scrollTo({ top: scene.offsetTop + focusCenter(i) * span, behavior: "smooth" });
  }));

  // Only decode the video while the scene is on screen.
  if (video && "IntersectionObserver" in window) {
    new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) video.play().catch(() => {});
      else video.pause();
    }).observe(scene);
  }
})();
