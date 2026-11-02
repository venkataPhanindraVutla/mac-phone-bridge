/* BRAND: rename here. The working name; every [data-brand] element is filled from it.
   Also update the literals marked "BRAND" in index.html's <head> and in 404.html. */
const BRAND = "Mac Phone Bridge";

(function () {
  "use strict";
  var doc = document.documentElement;
  doc.classList.add("js");

  document.querySelectorAll("[data-brand]").forEach(function (el) { el.textContent = BRAND; });

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* Header border once the page scrolls */
  var top = document.querySelector(".top");
  var onScroll = function () { top.classList.toggle("scrolled", window.scrollY > 8); };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* Hero preview: tabs, autoplay, per-state steps -------------------------- */
  var stage = document.querySelector(".stage");
  var tabs = Array.prototype.slice.call(document.querySelectorAll(".tab"));
  var panel = document.getElementById("demo-panel");
  var cap = document.querySelector(".cap");
  var captions = {
    notifications: "Phone notifications arrive as Mac notifications, with Reply and Copy code. The menu bar shows the phone's battery, signal and Wi-Fi.",
    calls: "See who's calling, then answer, decline, mute or hang up from the Mac. The call's audio stays on your phone.",
    files: "Drop files on the Phone window to send them, browse the phone's storage, and get screenshots on your Desktop as you take them.",
    mirroring: "Full mode puts the phone's screen in a Mac window, with its sound. Type into any app with the Mac's keyboard."
  };
  var DURATION = 6500;
  var current = 0, elapsed = 0, last = 0, autoplay = !reduce.matches, hovering = false, visible = true;
  var timers = [];
  var typed = stage.querySelector(".typed");
  var fullText = typed ? typed.getAttribute("data-text") : "";

  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function later(fn, ms) { timers.push(setTimeout(fn, ms)); }

  function enterState(name) {
    clearTimers();
    stage.setAttribute("data-step", "1");
    if (typed) typed.textContent = reduce.matches ? fullText : "";
    if (reduce.matches) return;
    if (name === "notifications") later(function () { stage.setAttribute("data-step", "2"); }, 2900);
    if (name === "calls") later(function () { stage.setAttribute("data-step", "2"); }, 2800);
    if (name === "mirroring" && typed) {
      var chars = Array.from(fullText), i = 0;
      var tick = function () {
        i++;
        typed.textContent = chars.slice(0, i).join("");
        if (i < chars.length) later(tick, 70 + Math.random() * 90);
      };
      later(tick, 900);
    }
  }

  function select(i, fromUser) {
    current = (i + tabs.length) % tabs.length;
    var tab = tabs[current], name = tab.getAttribute("data-state");
    tabs.forEach(function (t, j) {
      var on = j === current;
      t.setAttribute("aria-selected", on ? "true" : "false");
      t.tabIndex = on ? 0 : -1;
      t.style.setProperty("--p", 0);
    });
    stage.setAttribute("data-state", name);
    panel.setAttribute("aria-labelledby", tab.id);
    cap.textContent = captions[name];
    elapsed = 0;
    enterState(name);
    if (fromUser) stopAutoplay();
  }

  function stopAutoplay() {
    autoplay = false;
    document.querySelector(".demo").classList.add("autoplay-off");
  }

  tabs.forEach(function (t, i) {
    t.addEventListener("click", function () { select(i, true); });
    t.addEventListener("keydown", function (e) {
      var k = e.key, n = null;
      if (k === "ArrowRight" || k === "ArrowDown") n = current + 1;
      else if (k === "ArrowLeft" || k === "ArrowUp") n = current - 1;
      else if (k === "Home") n = 0;
      else if (k === "End") n = tabs.length - 1;
      if (n === null) return;
      e.preventDefault();
      select(n, true);
      tabs[current].focus();
    });
  });

  var demo = document.querySelector(".demo");
  demo.addEventListener("mouseenter", function () { hovering = true; });
  demo.addEventListener("mouseleave", function () { hovering = false; });
  demo.addEventListener("focusin", function () { hovering = true; });
  demo.addEventListener("focusout", function () { hovering = false; });

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (es) { visible = es[0].isIntersecting; }, { threshold: 0.25 }).observe(stage);
  }

  function frame(now) {
    var dt = last ? now - last : 0;
    last = now;
    if (autoplay && !hovering && visible && !document.hidden) {
      elapsed += dt;
      tabs[current].style.setProperty("--p", Math.min(elapsed / DURATION, 1));
      if (elapsed >= DURATION) select(current + 1, false);
    }
    if (autoplay) requestAnimationFrame(frame);
  }
  if (reduce.matches) stopAutoplay();
  select(0, false);
  if (autoplay) requestAnimationFrame(frame);

  /* Scroll reveals --------------------------------------------------------- */
  var reveals = document.querySelectorAll(".reveal");
  if (!reduce.matches && "IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add("is-in"); });
  }

  /* Copy buttons ----------------------------------------------------------- */
  document.querySelectorAll("[data-copy]").forEach(function (btn) {
    var label = btn.querySelector("span");
    btn.addEventListener("click", function () {
      var text = document.getElementById(btn.getAttribute("data-copy")).textContent;
      var done = function () {
        btn.classList.add("done");
        label.textContent = "Copied";
        setTimeout(function () { btn.classList.remove("done"); label.textContent = "Copy"; }, 1800);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, fallback);
      } else {
        fallback();
      }
      function fallback() {
        var ta = document.createElement("textarea");
        ta.value = text; ta.setAttribute("readonly", ""); ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.select();
        try { document.execCommand("copy"); done(); } catch (e) { label.textContent = "Select and copy"; }
        document.body.removeChild(ta);
      }
    });
  });
})();
