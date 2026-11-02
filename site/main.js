/* BRAND: rename here. The working name; every [data-brand] element is filled from it.
   Also update the literals marked "BRAND" in index.html's <head> and in 404.html. */
const BRAND = "Mac Phone Bridge";

(function () {
  "use strict";

  var doc = document.documentElement;
  var q = function (s, r) { return (r || document).querySelector(s); };
  var qa = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  qa("[data-brand]").forEach(function (el) { el.textContent = BRAND; });

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var hasGsap = !!(window.gsap && window.ScrollTrigger);
  var motion = !reduce && hasGsap;
  if (motion) doc.classList.add("motion");
  var wideMQ = window.matchMedia("(min-width: 900px) and (orientation: landscape)");
  var finePointer = window.matchMedia("(hover: hover) and (pointer: fine)").matches;

  /* ---------------------------------------------------------------- toasts */
  var toastBox = q(".toasts");
  function toast(msg) {
    var p = document.createElement("p");
    p.className = "toast";
    p.textContent = msg;
    toastBox.appendChild(p);
    while (toastBox.children.length > 2) toastBox.removeChild(toastBox.firstChild);
    setTimeout(function () { if (p.parentNode) p.parentNode.removeChild(p); }, 2800);
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(function () { return true; }, fallback);
    }
    return Promise.resolve(fallback());
    function fallback() {
      var ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta); ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      return ok;
    }
  }

  /* Build-from-source copy button */
  qa("[data-copy]").forEach(function (btn) {
    var label = btn.querySelector("span");
    btn.addEventListener("click", function () {
      var text = document.getElementById(btn.getAttribute("data-copy")).textContent;
      copyText(text).then(function (ok) {
        if (!ok) { label.textContent = "Select and copy"; return; }
        btn.classList.add("done"); label.textContent = "Copied";
        toast("Copied the clone commands");
        setTimeout(function () { btn.classList.remove("done"); label.textContent = "Copy"; }, 1800);
      });
    });
  });

  /* ---------------------------------------------------------------- scene fit */
  var scene = q(".scene");
  var sceneWrap = q(".scene-wrap");
  var pin = q(".story-pin");
  var head = 52;

  function layoutStory() {
    if (!scene) return;
    if (motion && !wideMQ.matches) {
      // Portrait: the scene takes what the tallest stage caption (1-5) leaves.
      var tallest = 0;
      qa(".stage-copy").forEach(function (c, i) { if (i > 0) tallest = Math.max(tallest, c.offsetHeight); });
      var h = pin.clientHeight - tallest - 18 - 26;
      sceneWrap.style.setProperty("--scene-h", Math.max(200, h) + "px");
    } else {
      sceneWrap.style.removeProperty("--scene-h");
    }
    fit();
  }
  function fit() {
    var cs = getComputedStyle(scene);
    var cw = parseFloat(cs.getPropertyValue("--cw")) || 1000;
    var ch = parseFloat(cs.getPropertyValue("--ch")) || 700;
    var r = sceneWrap.getBoundingClientRect();
    if (!r.width || !r.height) return;
    var s = Math.min(r.width / cw, r.height / ch) * (motion ? (wideMQ.matches ? .97 : .9) : 1);
    scene.style.setProperty("--s", s.toFixed(4));
  }
  function sceneScale() { return parseFloat(scene.style.getPropertyValue("--s")) || 1; }

  /* ---------------------------------------------------------------- kinetic words */
  function split(el) {
    if (el.getAttribute("data-split")) return qa(".wi", el);
    var words = el.textContent.trim().split(/\s+/);
    el.textContent = "";
    words.forEach(function (w, i) {
      var o = document.createElement("span"); o.className = "w";
      var n = document.createElement("span"); n.className = "wi"; n.textContent = w;
      o.appendChild(n); el.appendChild(o);
      if (i < words.length - 1) el.appendChild(document.createTextNode(" "));
    });
    el.setAttribute("data-split", "1");
    return qa(".wi", el);
  }

  if (motion) {
    qa(".kin").forEach(split);
    gsap.registerPlugin(ScrollTrigger);
    ScrollTrigger.config({ ignoreMobileResize: true });
    layoutStory();
    buildStory();
    buildSections();
  } else if (scene) {
    fit();
  }

  var resizeT;
  window.addEventListener("resize", function () {
    clearTimeout(resizeT);
    resizeT = setTimeout(function () { if (motion) { layoutStory(); ScrollTrigger.refresh(); } else if (scene) fit(); }, 120);
  });

  /* ---------------------------------------------------------------- the pinned story */
  function buildStory() {
    var copies = qa(".stage-copy");
    var bgs = qa(".bg");
    var steps = qa(".story-steps li");
    var macMove = q(".mac-move"), phoneMove = q(".phone-move"), rig = q(".rig");
    var pscreen = q(".pscreen", scene);
    var V = function (n) { return qa('[data-view="' + n + '"]', scene); };

    // Base poses per layout (the CSS ones apply only without motion).
    var pose = function () { return wideMQ.matches ? { rx: -11, ry: -17 } : { rx: -9, ry: -12 }; };
    gsap.set(rig, { rotationX: pose().rx, rotationY: pose().ry, transformPerspective: 0 });
    gsap.set(phoneMove, { rotationY: -8, rotation: -2 });

    // Everything starts hidden except the first screens.
    gsap.set(qa(".view", scene), { autoAlpha: 0 });
    gsap.set(V("p-onboard"), { autoAlpha: 1 });
    gsap.set(V("m-qr"), { autoAlpha: 1 });
    gsap.set(bgs.slice(1), { yPercent: 100 });
    copies.forEach(function (c, i) {
      if (i === 0) return;
      gsap.set(c, { autoAlpha: 0 });
      gsap.set(qa(".wi", c), { yPercent: 115 });
      gsap.set(c.querySelector(".lede"), { autoAlpha: 0, y: 14 });
    });

    // Typed reply in the mirror window, one character at a time.
    var typed = q(".typed", scene), chars = [];
    if (typed) {
      var t = typed.getAttribute("data-text"); typed.textContent = "";
      Array.from(t).forEach(function (ch) { var s = document.createElement("span"); s.textContent = ch; typed.appendChild(s); chars.push(s); });
      gsap.set(chars, { opacity: 0 });
      gsap.set(q(".typed-target", scene), { autoAlpha: 0 });
    }
    var pLast = qa(".ax-chat[data-view='p-chat'] .ax-msgs .out", scene).pop();
    if (pLast) gsap.set(pLast, { autoAlpha: 0 });

    // The flying copy of the phone screen carries the chat with it.
    var beamFace = q(".beam-face", scene);
    var chatClone = q('[data-view="p-chat"]', scene).cloneNode(true);
    chatClone.removeAttribute("data-view"); chatClone.removeAttribute("data-screen"); chatClone.classList.remove("view", "final");
    chatClone.style.opacity = 1; chatClone.style.visibility = "visible";
    qa(".ax-msgs .out", chatClone).pop().style.visibility = "hidden";
    beamFace.appendChild(chatClone);

    // Geometry, in canvas units, measured on every refresh.
    var G = {};
    function rel(el) {
      var s = sceneScale(), sr = scene.getBoundingClientRect(), r = el.getBoundingClientRect();
      return { x: (r.left - sr.left) / s, y: (r.top - sr.top) / s, w: r.width / s, h: r.height / s };
    }
    function measure() {
      var heads = rel(q('[data-view="p-heads"]', scene));
      var note = rel(q('[data-view="m-note1"]', scene));
      var ps = rel(pscreen);
      var status = rel(q(".mx-status", scene));
      var mir = rel(q(".mx-mirror-screen", scene));
      G.heads = heads; G.note = note; G.ps = ps; G.mir = mir;
      measureFile();
      var cur = q(".mx-cursor", scene), ans = q(".mx-call .green", scene);
      G.cur = { x: ans.offsetLeft + ans.offsetParent.offsetLeft + 20, y: ans.offsetTop + ans.offsetParent.offsetTop + 8 };
      void cur;
      chatClone.style.transform = "scale(" + (ps.w / 198) + "," + (ps.h / 426) + ")";
      // Portrait: on the first stage the devices sit lower, under the taller headline.
      if (!wideMQ.matches) {
        var c0 = copies[0].offsetHeight + 18 + 10;
        var sceneTop = pin.clientHeight - sceneWrap.offsetHeight;
        G.drop = Math.max(0, c0 - sceneTop);
      } else G.drop = 0;
    }
    function measureFile() {
      var ps = rel(pscreen), status = rel(q(".mx-status", scene));
      G.p0 = { x: ps.x + ps.w * .25, y: ps.y + ps.h * .8 };
      G.p2 = { x: status.x + status.w / 2, y: status.y + status.h / 2 };
      G.p1 = { x: G.p2.x - 40, y: Math.min(G.p0.y, G.p2.y) - 120 };
      qa(".fly-path i", scene).forEach(function (d, i, all) {
        var p = bez((i + 1) / (all.length + 1));
        gsap.set(d, { x: p.x, y: p.y });
      });
    }
    function bez(t) {
      var a = G.p0, b = G.p1, c = G.p2, u = 1 - t;
      return { x: u * u * a.x + 2 * u * t * b.x + t * t * c.x, y: u * u * a.y + 2 * u * t * b.y + t * t * c.y };
    }
    measure();

    var tl = gsap.timeline({ defaults: { ease: "power2.inOut" } });
    function inV(n, at, d) { return tl.to(V(n), { autoAlpha: 1, duration: d || .08 }, at); }
    function outV(n, at, d) { return tl.to(V(n), { autoAlpha: 0, duration: d || .06 }, at); }
    // Phone screens change like screens do: the new one slides over the old.
    function swapP(from, to, at) {
      tl.fromTo(V(to), { autoAlpha: 0, xPercent: 18 }, { autoAlpha: 1, xPercent: 0, duration: .12, ease: "power3.out" }, at);
      tl.to(V(from), { autoAlpha: 0, duration: .05 }, at + .07);
    }

    // Stage copy and colour block swaps.
    function swap(i, at) {
      tl.to(bgs[i], { yPercent: 0, duration: .5, ease: "power3.inOut" }, at);
      var prev = copies[i - 1], next = copies[i];
      tl.to(qa(".wi", prev), { yPercent: -115, duration: .3, stagger: .015, ease: "power2.in" }, at);
      tl.to(qa(".lede, .cta-row, .status-note", prev), { autoAlpha: 0, y: -12, duration: .25 }, at);
      tl.set(prev, { autoAlpha: 0 }, at + .4);
      tl.set(next, { autoAlpha: 1 }, at + .28);
      tl.to(qa(".wi", next), { yPercent: 0, duration: .4, stagger: .03, ease: "power3.out" }, at + .3);
      tl.to(next.querySelector(".lede"), { autoAlpha: 1, y: 0, duration: .3, ease: "power2.out" }, at + .48);
    }

    // Slow layered drift across the whole sequence.
    tl.to(macMove, { x: -16, z: -20, duration: 6.1, ease: "none" }, 0);
    tl.fromTo(sceneWrap, { y: function () { return G.drop; } }, { y: 0, duration: .7, ease: "power2.inOut" }, .05);

    /* 1. Pair */
    swap(1, 1);
    tl.to(phoneMove, { x: -14, y: -10, rotationY: -15, rotation: 0, duration: .6 }, 1.0);
    swapP("p-onboard", "p-scan", 1.15);
    inV("m-pair", 1.1, .2);
    tl.from(V("m-pair"), { scale: .9, duration: .25, ease: "back.out(1.6)" }, 1.1);
    tl.fromTo(q(".ax-cam-qr", scene), { autoAlpha: 0, scale: .7 }, { autoAlpha: .92, scale: 1, duration: .2 }, 1.3);
    tl.fromTo(q(".ax-scanline", scene), { yPercent: 0 }, { yPercent: 5200, duration: .3, ease: "none" }, 1.3);
    outV("m-qr", 1.52); inV("m-code", 1.54);
    swapP("p-scan", "p-code", 1.52);
    outV("m-code", 1.74); inV("m-paired", 1.76);
    swapP("p-code", "p-home", 1.74);
    tl.from(q(".mx-okc", scene), { scale: 0, duration: .12, ease: "back.out(3)" }, 1.76);

    /* 2. Notifications */
    swap(2, 2);
    outV("m-pair", 2.05);
    tl.fromTo(V("p-heads"), { autoAlpha: 0, y: -30 }, { autoAlpha: 1, y: 0, duration: .15, ease: "power3.out" }, 2.15);
    var flyNote = q(".fly-note", scene);
    var headsEl = q('[data-view="p-heads"]', scene), note1El = q('[data-view="m-note1"]', scene);
    tl.set(flyNote, { autoAlpha: 1, x: function () { G.heads = rel(headsEl); G.note = rel(note1El); return G.heads.x; }, y: function () { return G.heads.y; }, scaleX: function () { return G.heads.w / 182; }, scaleY: function () { return G.heads.w / 182; }, rotation: 0 }, 2.36);
    tl.set(V("p-heads"), { autoAlpha: 0 }, 2.36);
    tl.to(flyNote, { x: function () { return G.note.x; }, duration: .4, ease: "power1.inOut" }, 2.36);
    tl.to(flyNote, { y: function () { return Math.min(G.heads.y, G.note.y) - 120; }, duration: .2, ease: "power2.out" }, 2.36);
    tl.to(flyNote, { y: function () { return G.note.y; }, duration: .2, ease: "power2.in" }, 2.56);
    tl.to(flyNote, { scaleX: function () { return G.note.w / 182; }, scaleY: function () { return G.note.w / 182; }, keyframes: { rotation: [0, -8, 4, 0] }, duration: .4 }, 2.36);
    inV("m-note1", 2.74, .06);
    tl.to(flyNote, { autoAlpha: 0, duration: .06 }, 2.76);
    tl.fromTo(V("m-note2"), { autoAlpha: 0, y: -14 }, { autoAlpha: 1, y: 0, duration: .12 }, 2.8);

    /* 3. Files */
    swap(3, 3);
    tl.to(qa(".mx-note", scene), { x: 300, duration: .25, stagger: .05, ease: "power2.in" }, 3.0);
    tl.set(qa(".mx-note", scene), { autoAlpha: 0 }, 3.3);
    var sheet = q(".ax-sheet", scene);
    inV("p-share", 3.05, .1);
    tl.fromTo(sheet, { yPercent: 100 }, { yPercent: 0, duration: .2, ease: "power3.out" }, 3.05);
    tl.to(q(".tg-mac", scene), { keyframes: { scale: [1, .86, 1.05, 1] }, duration: .14 }, 3.24);
    var dots = qa(".fly-path i", scene);
    tl.to(dots, { opacity: 1, duration: .04, stagger: .035 }, 3.3);
    var flyFile = q(".fly-file", scene), proxy = { t: 0 };
    tl.call(measureFile, null, 3.29);
    tl.set(flyFile, { autoAlpha: 1, x: function () { return G.p0.x; }, y: function () { return G.p0.y; } }, 3.34);
    tl.fromTo(proxy, { t: 0 }, { t: 1, duration: .36, ease: "power1.inOut", onUpdate: function () { var p = bez(proxy.t); gsap.set(flyFile, { x: p.x, y: p.y, rotation: (proxy.t - .5) * 50 }); } }, 3.34);
    tl.to(flyFile, { scale: .4, duration: .1 }, 3.62);
    tl.to(flyFile, { autoAlpha: 0, duration: .05 }, 3.7);
    tl.to(dots, { opacity: 0, duration: .04, stagger: .03 }, 3.5);
    tl.to(sheet, { yPercent: 100, duration: .15 }, 3.66); outV("p-share", 3.72, .08);
    tl.set(V("m-xfer-a"), { display: "flex" }, 3.6);
    inV("m-menu", 3.64, .08);
    inV("m-xfer-a", 3.64, .05);
    tl.set(V("m-xfer-a"), { display: "none" }, 3.82);
    tl.set(V("m-xfer-b"), { display: "flex", autoAlpha: 1 }, 3.82);

    /* 4. Calls */
    swap(4, 4);
    outV("m-menu", 4.0, .08);
    tl.set(V("m-xfer-b"), { display: "none" }, 4.1);
    swapP("p-home", "p-callin", 4.1);
    var pStatus = q(".ax-status", pscreen);
    tl.to(pStatus, { color: "#ffffff", duration: .05 }, 4.12);
    tl.to(phoneMove, { keyframes: { rotation: [0, -4, 4, -4, 4, -3, 3, 0] }, duration: .4, ease: "none" }, 4.12);
    tl.fromTo(V("m-call"), { autoAlpha: 0, x: 40 }, { autoAlpha: 1, x: 0, duration: .15, ease: "power3.out" }, 4.15);
    var cursor = q(".mx-cursor", scene);
    tl.fromTo(cursor, { autoAlpha: 0, x: 0, y: 0 }, { autoAlpha: 1, duration: .05 }, 4.3);
    tl.to(cursor, { x: function () { return G.cur.x - 300; }, y: function () { return G.cur.y - 300; }, duration: .2, ease: "power2.out" }, 4.3);
    tl.to(q(".mx-call .green", scene), { keyframes: { scale: [1, .86, 1] }, duration: .08 }, 4.52);
    outV("m-call", 4.6, .08);
    swapP("p-callin", "p-callon", 4.6);
    tl.to(cursor, { autoAlpha: 0, duration: .05 }, 4.62);
    tl.set(V("m-callline"), { display: "flex", autoAlpha: 1 }, 4.62);
    inV("m-menu", 4.66, .08);

    /* 5. Full mode */
    swap(5, 5);
    outV("m-menu", 5.0, .08);
    tl.set(V("m-callline"), { display: "none" }, 5.1);
    tl.to(phoneMove, { x: 10, rotationY: -6, rotation: -2, duration: .5 }, 5.0);
    swapP("p-callon", "p-chat", 5.05);
    tl.to(pStatus, { color: "#231917", duration: .05 }, 5.1);
    var beam = q(".fly-beam", scene), ghosts = qa(".fly-beam .g", scene);
    var mirEl = q(".mx-mirror-screen", scene);
    tl.set(beam, { autoAlpha: 1, x: function () { G.ps = rel(pscreen); G.mir = rel(mirEl); chatClone.style.transform = "scale(" + (G.ps.w / 198) + "," + (G.ps.h / 426) + ")"; return G.ps.x; }, y: function () { return G.ps.y; }, width: function () { return G.ps.w; }, height: function () { return G.ps.h; }, scale: 1, rotation: 0 }, 5.2);
    tl.to(beam, { scale: 1.06, y: function () { return G.ps.y - 24; }, rotation: -3, duration: .1, ease: "power2.out" }, 5.2);
    tl.to(ghosts, { opacity: .7, duration: .04, stagger: .02 }, 5.28);
    tl.to(ghosts, { x: function (i) { return 18 * (i + 1); }, y: function (i) { return 14 * (i + 1); }, duration: .3, ease: "power1.in" }, 5.3);
    tl.to(beam, { x: function () { return G.mir.x; }, y: function () { return G.mir.y; }, scaleX: function () { return G.mir.w / G.ps.w; }, scaleY: function () { return G.mir.h / G.ps.h; }, rotation: 0, duration: .36, ease: "power3.inOut" }, 5.3);
    tl.to(ghosts, { opacity: 0, duration: .08 }, 5.58);
    inV("m-mirror", 5.42, .14);
    tl.to(beam, { autoAlpha: 0, duration: .06 }, 5.68);
    tl.set(q(".typed-target", scene), { autoAlpha: 1 }, 5.74);
    tl.to(chars, { opacity: 1, duration: .01, stagger: .2 / Math.max(1, chars.length) }, 5.74);
    if (pLast) tl.to(pLast, { autoAlpha: 1, duration: .05 }, 5.96);
    tl.to({}, { duration: .15 }, 6.0);

    // Chapter bars and text tone follow the timeline.
    var lastIdx = -1;
    function syncChapter() {
      var idx = Math.max(0, Math.min(5, Math.floor(tl.time() + .02)));
      if (idx === lastIdx) return;
      lastIdx = idx;
      steps.forEach(function (s, i) { s.classList.toggle("on", i <= idx); });
      pin.setAttribute("data-tone", idx === 2 || idx === 4 ? "dark" : "light");
    }
    syncChapter();
    tl.eventCallback("onUpdate", syncChapter);

    var snapPoints = [0, 1.97, 2.97, 3.97, 4.97, tl.duration()].map(function (t) { return t / tl.duration(); });
    ScrollTrigger.create({
      trigger: ".story",
      start: function () { return "top " + head + "px"; },
      end: function () { return "+=" + Math.round(window.innerHeight * (wideMQ.matches ? 5.2 : 4.2)); },
      pin: pin,
      anticipatePin: 1,
      scrub: wideMQ.matches ? .7 : .35,
      animation: tl,
      invalidateOnRefresh: true,
      snap: wideMQ.matches ? { snapTo: snapPoints, inertia: false, duration: { min: .2, max: .6 }, delay: .15, ease: "power1.inOut" } : false,
      onRefreshInit: function () { gsap.set(rig, { rotationX: pose().rx, rotationY: pose().ry }); },
      onRefresh: measure
    });
    ScrollTrigger.addEventListener("refreshInit", function () { layoutStory(); });

    // The one load moment: the headline sets itself, the devices rise into place.
    gsap.from(qa(".wi", copies[0]), { yPercent: 115, duration: .9, stagger: .06, ease: "power4.out", delay: .1 });
    gsap.from(qa(".lede, .cta-row, .status-note", copies[0]), { autoAlpha: 0, y: 14, duration: .6, stagger: .08, delay: .55, ease: "power2.out" });
    gsap.from([macMove, phoneMove], { y: 240, duration: 1.3, stagger: .12, ease: "power3.out", delay: .2 });

    // Pointer tilt on desktop, a slow float on touch.
    var visible = true;
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) { visible = es[0].isIntersecting; if (floatTw) floatTw[visible ? "resume" : "pause"](); }, { threshold: 0 }).observe(pin);
    }
    var floatTw = null;
    if (finePointer) {
      var rx = gsap.quickTo(rig, "rotationX", { duration: .9, ease: "power3.out" });
      var ry = gsap.quickTo(rig, "rotationY", { duration: .9, ease: "power3.out" });
      window.addEventListener("pointermove", function (e) {
        if (!visible) return;
        var nx = e.clientX / window.innerWidth * 2 - 1, ny = e.clientY / window.innerHeight * 2 - 1;
        var p = pose();
        rx(p.rx - ny * 5); ry(p.ry + nx * 8);
        scene.style.setProperty("--gx", (nx * 18).toFixed(1) + "%");
      }, { passive: true });
    } else {
      floatTw = gsap.to(rig, { y: -8, rotationZ: .6, duration: 3.2, ease: "sine.inOut", yoyo: true, repeat: -1 });
    }
  }

  /* ---------------------------------------------------------------- section motion */
  function buildSections() {
    qa(".block .kin, .foot .kin").forEach(function (h) {
      gsap.fromTo(qa(".wi", h), { yPercent: 115 }, {
        yPercent: 0, stagger: .06, ease: "power2.out",
        scrollTrigger: { trigger: h, start: "top 92%", end: "top 58%", scrub: .5 }
      });
    });
    qa(".shutter").forEach(function (sh) {
      gsap.fromTo(qa("i", sh), { scaleX: 1 }, {
        scaleX: 0, stagger: .08, ease: "none",
        scrollTrigger: { trigger: sh.parentNode, start: "top bottom", end: "top 35%", scrub: .4 }
      });
    });
    qa(".priv b").forEach(function (b, i) {
      gsap.fromTo(b, { xPercent: i % 2 ? 14 : -14 }, {
        xPercent: 0, ease: "none",
        scrollTrigger: { trigger: b, start: "top bottom", end: "top 55%", scrub: .5 }
      });
    });
    qa(".figs dt").forEach(function (d, i) {
      gsap.fromTo(d, { yPercent: 40, scaleY: .7, transformOrigin: "50% 100%" }, {
        yPercent: 0, scaleY: 1, ease: "power2.out",
        scrollTrigger: { trigger: d, start: "top 95%", end: "top 65%", scrub: .5 }
      });
    });
    qa(".road-v").forEach(function (v) {
      gsap.fromTo(v, { xPercent: -18 }, { xPercent: 0, ease: "none", scrollTrigger: { trigger: v, start: "top bottom", end: "top 60%", scrub: .5 } });
    });
    gsap.fromTo(".foot-mark", { yPercent: 60 }, { yPercent: 0, ease: "none", scrollTrigger: { trigger: ".foot", start: "top bottom", end: "top 40%", scrub: .5 } });
    var pulse = q(".link-pulse");
    if (pulse) {
      gsap.fromTo(pulse, { x: 0 }, { x: 330, duration: 1.6, ease: "power1.inOut", repeat: -1, yoyo: true,
        scrollTrigger: { trigger: ".link-fig", start: "top bottom", end: "bottom top", toggleActions: "play pause resume pause" } });
    }
  }

  /* ---------------------------------------------------------------- playground */
  (function playground() {
    var pg = q("#pg");
    if (!pg) return;
    var phone = q(".pg-phone"), msgs = q(".pg-msgs"), mirror = q(".pg-msgs-mirror");
    var form = q(".pg-compose"), input = q("#pg-input"), ptext = q(".pg-ptext"), pill = q(".pg-kbd-pill");
    var drop = q(".pg-drop"), dropList = q(".pg-drop-list"), dropHint = q(".pg-drop-hint");
    var statusBtn = q(".pg-status"), menu = q("#pg-menu"), ringBtn = q(".pg-ring"), find = q(".pg-find");
    var macCall = q(".pg-call"), macOn = q(".pg-oncall"), pCall = q(".pg-pcall"), pOn = q(".pg-pon");
    var callMenu = q(".pg-callmenu"), again = q(".pg-again"), muteBtn = q('[data-act="mute"]');
    var timerEls = qa(".pg-timer");
    var state = { call: "idle", finding: false, secs: 0, timer: null, findT: null, rang: false, replies: 0 };
    var received = {};

    function syncMirror() {
      var c = msgs.cloneNode(true);
      qa(".pg-photo", c).forEach(function (b) { var s = document.createElement("span"); s.innerHTML = b.innerHTML; b.parentNode.replaceChild(s, b); });
      mirror.innerHTML = c.innerHTML;
    }
    function addMsg(text, dir) {
      var p = document.createElement("p"); p.className = dir; p.textContent = text;
      msgs.appendChild(p);
      while (msgs.children.length > 9) msgs.removeChild(msgs.firstElementChild);
      syncMirror();
    }
    syncMirror();

    function shake() { phone.classList.toggle("ringing", state.finding || state.call === "ringing"); }

    /* Typing: the Mac's keyboard into the mirrored chat */
    function syncTyping() {
      var v = input.value;
      ptext.textContent = v || "Message";
      ptext.classList.toggle("typing", !!v);
      pill.hidden = !(v || document.activeElement === input);
    }
    input.addEventListener("input", syncTyping);
    input.addEventListener("focus", syncTyping);
    input.addEventListener("blur", function () { setTimeout(syncTyping, 0); });
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var v = input.value.trim();
      if (!v) return;
      addMsg(v, "out");
      input.value = ""; syncTyping();
      var replies = ["Ha, typed on the Mac?", "See you at 7", "Got it"];
      var r = replies[state.replies++ % replies.length];
      setTimeout(function () { addMsg(r, "in"); }, 1300);
    });
    // On a desktop keyboard, start typing anywhere near the playground.
    var pgInView = false;
    document.addEventListener("keydown", function (e) {
      if (!pgInView || e.metaKey || e.ctrlKey || e.altKey || e.key.length !== 1 || e.key === " ") return;
      var a = document.activeElement;
      if (a && a !== document.body && a !== document.documentElement) return;
      input.focus({ preventScroll: true });
    });

    /* Photos: drag to the Mac, or press to send */
    function receive(btn) {
      var name = btn.getAttribute("data-name"), n = (received[name] || 0) + 1;
      received[name] = n;
      var shown = n === 1 ? name : name.replace(/(\.\w+)$/, " " + n + "$1");
      var li = document.createElement("li");
      li.innerHTML = '<svg aria-hidden="true"><use href="#' + btn.getAttribute("data-photo") + '"/></svg><span></span>';
      li.querySelector("span").textContent = shown;
      dropList.appendChild(li);
      while (dropList.children.length > 4) dropList.removeChild(dropList.firstElementChild);
      dropHint.textContent = "Received " + shown;
      btn.classList.add("sent");
      toast("Received " + shown + " in Downloads");
      if (!reduce && li.animate) li.animate([{ transform: "scale(.4)", opacity: 0 }, { transform: "scale(1)", opacity: 1 }], { duration: 260, easing: "cubic-bezier(.2,.9,.3,1.3)" });
    }
    function ghostFor(btn) {
      var g = document.createElement("div");
      g.className = "pg-ghost"; g.setAttribute("aria-hidden", "true");
      g.innerHTML = '<svg><use href="#' + btn.getAttribute("data-photo") + '"/></svg>';
      document.body.appendChild(g);
      return g;
    }
    function center(el) { var r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
    function overDrop(x, y) { var r = drop.getBoundingClientRect(); return x >= r.left - 16 && x <= r.right + 16 && y >= r.top - 16 && y <= r.bottom + 16; }

    qa(".pg-photo").forEach(function (btn) {
      var d = null;
      btn.addEventListener("pointerdown", function (e) {
        if (e.button !== 0) return;
        d = { id: e.pointerId, sx: e.clientX, sy: e.clientY, x: e.clientX, y: e.clientY, g: null, moved: false, raf: 0 };
        try { btn.setPointerCapture(e.pointerId); } catch (err) { /* older browsers */ }
      });
      btn.addEventListener("pointermove", function (e) {
        if (!d || e.pointerId !== d.id) return;
        d.x = e.clientX; d.y = e.clientY;
        if (!d.moved && Math.hypot(d.x - d.sx, d.y - d.sy) > 6) {
          d.moved = true; d.g = ghostFor(btn);
          var loop = function () {
            if (!d || !d.g) return;
            d.g.style.transform = "translate3d(" + d.x + "px," + d.y + "px,0) rotate(-6deg) scale(1.1)";
            drop.classList.toggle("over", overDrop(d.x, d.y));
            var edge = 70, vy = d.y > window.innerHeight - edge ? 10 : d.y < edge + head ? -10 : 0;
            if (vy) window.scrollBy(0, vy);
            d.raf = requestAnimationFrame(loop);
          };
          loop();
        }
      });
      function end(e) {
        if (!d || e.pointerId !== d.id) return;
        var cur = d; d = null;
        cancelAnimationFrame(cur.raf);
        drop.classList.remove("over");
        if (!cur.moved) return;
        btn.dataset.dragged = "1";
        var g = cur.g;
        if (e.type === "pointerup" && overDrop(cur.x, cur.y)) {
          receive(btn);
          if (g.animate && !reduce) g.animate([{ transform: g.style.transform, opacity: 1 }, { transform: "translate3d(" + cur.x + "px," + cur.y + "px,0) scale(.3)", opacity: 0 }], { duration: 200 }).onfinish = function () { g.remove(); };
          else g.remove();
        } else {
          var h = center(btn);
          if (g.animate && !reduce) g.animate([{ transform: g.style.transform }, { transform: "translate3d(" + h.x + "px," + h.y + "px,0) scale(.9)" }], { duration: 260, easing: "ease-out" }).onfinish = function () { g.remove(); };
          else g.remove();
          toast("Drop it on Downloads to send it");
        }
      }
      btn.addEventListener("pointerup", end);
      btn.addEventListener("pointercancel", end);
      btn.addEventListener("click", function () {
        if (btn.dataset.dragged) { delete btn.dataset.dragged; return; }
        // Keyboard and tap: send it across.
        if (reduce) { receive(btn); return; }
        var a = center(btn), b = center(drop), g = ghostFor(btn);
        var mid = { x: (a.x + b.x) / 2 + 40, y: Math.min(a.y, b.y) - 80 };
        var anim = g.animate([
          { transform: "translate3d(" + a.x + "px," + a.y + "px,0) scale(1)" },
          { transform: "translate3d(" + mid.x + "px," + mid.y + "px,0) rotate(-12deg) scale(1.15)", offset: .5 },
          { transform: "translate3d(" + b.x + "px," + b.y + "px,0) scale(.4)", opacity: .2 }
        ], { duration: 650, easing: "cubic-bezier(.5,0,.3,1)" });
        anim.onfinish = function () { g.remove(); receive(btn); };
      });
    });

    /* Menu bar: the phone menu, Ring phone */
    function openMenu(open, focusFirst) {
      menu.hidden = !open;
      statusBtn.setAttribute("aria-expanded", open ? "true" : "false");
      if (open && focusFirst) ringBtn.focus();
    }
    statusBtn.addEventListener("click", function (e) { openMenu(menu.hidden, e.detail === 0); });
    document.addEventListener("click", function (e) { if (!menu.hidden && !menu.contains(e.target) && !statusBtn.contains(e.target)) openMenu(false); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !menu.hidden) { openMenu(false); statusBtn.focus(); } });

    function findStart() {
      state.finding = true; find.hidden = false; ringBtn.textContent = "Stop ringing"; shake();
      toast("Ringing Asha's phone");
      clearTimeout(state.findT); state.findT = setTimeout(findStop, 9000);
    }
    function findStop() {
      if (!state.finding) return;
      state.finding = false; find.hidden = true; ringBtn.textContent = "Ring phone"; shake();
      clearTimeout(state.findT);
    }

    /* Calls */
    function fmt(s) { return String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0"); }
    function setCall(next) {
      state.call = next;
      macCall.hidden = pCall.hidden = next !== "ringing";
      macOn.hidden = pOn.hidden = callMenu.hidden = next !== "active";
      again.hidden = next !== "idle" || !state.rang;
      clearInterval(state.timer);
      if (next === "active") {
        state.secs = 0; timerEls.forEach(function (t) { t.textContent = "00:00"; });
        state.timer = setInterval(function () { state.secs++; timerEls.forEach(function (t) { t.textContent = fmt(state.secs); }); }, 1000);
      }
      muteBtn.setAttribute("aria-pressed", "false"); muteBtn.textContent = "Mute";
      q(".pg-pscreen").classList.toggle("on-call", next !== "idle");
      shake();
    }
    function ring() { state.rang = true; setCall("ringing"); toast("Incoming call from Mum"); }

    pg.addEventListener("click", function (e) {
      var b = e.target.closest("[data-act]");
      if (!b) return;
      var act = b.getAttribute("data-act");
      if (act === "copy") {
        var code = b.getAttribute("data-code");
        copyText(code).then(function (ok) { toast(ok ? "Copied " + code : "Couldn't copy. The code is " + code); });
      } else if (act === "ring") {
        state.finding ? findStop() : findStart();
        openMenu(false);
      } else if (act === "stopring") {
        findStop(); toast("Stopped ringing");
      } else if (act === "answer") {
        setCall("active"); toast("Answered. The audio stays on the phone.");
      } else if (act === "decline") {
        setCall("idle"); toast("Declined");
      } else if (act === "hangup") {
        setCall("idle"); toast("Call ended");
      } else if (act === "mute") {
        var on = b.getAttribute("aria-pressed") !== "true";
        b.setAttribute("aria-pressed", on ? "true" : "false"); b.textContent = on ? "Unmute" : "Mute";
      } else if (act === "callagain") {
        ring();
      }
    });

    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) {
        pgInView = es[0].isIntersecting;
        if (pgInView && !state.rang && state.call === "idle") {
          setTimeout(function () { if (!state.rang && state.call === "idle") ring(); }, 2200);
        }
      }, { threshold: .35 }).observe(pg);
    } else { pgInView = true; }
  })();
})();
