/* RLPlayer for macOS — site behaviour.
   Vanilla JS, no dependencies. Everything degrades without it. */
(function () {
  'use strict';

  var docEl = document.documentElement;
  var reduceQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;

  function prefersReduced() {
    return !!(reduceQuery && reduceQuery.matches);
  }

  function $(selector, scope) {
    return (scope || document).querySelector(selector);
  }

  function $all(selector, scope) {
    return Array.prototype.slice.call((scope || document).querySelectorAll(selector));
  }

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  /* ---------------------------------------------------------------------
     1. Header state, scroll progress, nav highlight
     --------------------------------------------------------------------- */
  var header = document.getElementById('siteHeader');
  var progressBar = document.getElementById('scrollProgress');
  var navLinks = $all('.site-nav__link');
  var navTargets = navLinks.map(function (link) {
    var href = link.getAttribute('href') || '';
    return href.charAt(0) === '#' ? document.getElementById(href.slice(1)) : null;
  });

  function updateHeaderAndProgress() {
    var y = window.pageYOffset || docEl.scrollTop || 0;
    if (header) header.classList.toggle('is-scrolled', y > 8);
    if (progressBar) {
      var max = docEl.scrollHeight - window.innerHeight;
      var ratio = max > 0 ? clamp(y / max, 0, 1) : 0;
      progressBar.style.transform = 'scaleX(' + ratio.toFixed(4) + ')';
    }
  }

  function updateNavHighlight() {
    if (!navLinks.length) return;
    var line = 130;
    var current = -1;
    for (var i = 0; i < navTargets.length; i += 1) {
      var target = navTargets[i];
      if (target && target.getBoundingClientRect().top <= line) current = i;
    }
    for (var j = 0; j < navLinks.length; j += 1) {
      navLinks[j].classList.toggle('is-active', j === current);
    }
  }

  /* ---------------------------------------------------------------------
     2. Mobile navigation
     --------------------------------------------------------------------- */
  var navToggle = document.getElementById('navToggle');
  var mobileNav = document.getElementById('mobileNav');
  var desktopQuery = window.matchMedia ? window.matchMedia('(min-width: 921px)') : null;

  function setNav(open) {
    if (!navToggle || !mobileNav) return;
    mobileNav.hidden = !open;
    navToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    navToggle.setAttribute('aria-label', open ? '关闭菜单' : '打开菜单');
    document.body.classList.toggle('nav-open', open);
    if (open) {
      var first = mobileNav.querySelector('a');
      if (first) first.focus();
    }
  }

  if (navToggle && mobileNav) {
    navToggle.addEventListener('click', function () {
      setNav(mobileNav.hidden);
    });

    $all('a', mobileNav).forEach(function (link) {
      link.addEventListener('click', function () {
        setNav(false);
      });
    });

    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && !mobileNav.hidden) {
        setNav(false);
        navToggle.focus();
      }
    });

    function closeOnDesktop(event) {
      if (event.matches) setNav(false);
    }
    if (desktopQuery) {
      if (desktopQuery.addEventListener) desktopQuery.addEventListener('change', closeOnDesktop);
      else if (desktopQuery.addListener) desktopQuery.addListener(closeOnDesktop);
    }
  }

  /* ---------------------------------------------------------------------
     3. Reveal on scroll
     --------------------------------------------------------------------- */
  var revealItems = $all('[data-reveal]');

  if (revealItems.length) {
    if ('IntersectionObserver' in window) {
      revealItems.forEach(function (el) {
        var parent = el.parentElement;
        if (!parent) return;
        var siblings = Array.prototype.filter.call(parent.children, function (child) {
          return child.hasAttribute && child.hasAttribute('data-reveal');
        });
        var index = siblings.indexOf(el);
        if (index > 0) {
          el.style.setProperty('--reveal-delay', Math.min(index, 5) * 60 + 'ms');
        }
      });

      var revealObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-in');
            revealObserver.unobserve(entry.target);
          }
        });
      }, { rootMargin: '0px 0px -10% 0px', threshold: 0.08 });

      revealItems.forEach(function (el) { revealObserver.observe(el); });
    } else {
      revealItems.forEach(function (el) { el.classList.add('is-in'); });
    }
  }

  /* ---------------------------------------------------------------------
     4. Signal chain: active stage, pulse, progress fallback
     --------------------------------------------------------------------- */
  var chainSection = document.getElementById('signal');
  var chainStages = $all('.chain-stage');
  var chainState = document.getElementById('chainState');
  var chainPulse = document.getElementById('chainPulse');
  var chainPulseGlow = document.getElementById('chainPulseGlow');
  var chainPulsePath = document.getElementById('chainPulsePath');
  var chainFill = $('.chain-progress__fill');
  var chainNodeEls = $all('.chain-node, .chain-edge');
  var chainMap = {
    0: ['source'],
    1: ['route', 'direct'],
    2: ['dsp'],
    3: ['output']
  };
  var activeStage = -1;
  var activeNodes = [];

  function supportsViewTimeline() {
    try {
      return !!(window.CSS && CSS.supports && CSS.supports('animation-timeline: view()'));
    } catch (err) {
      return false;
    }
  }
  var hasScrollTimeline = supportsViewTimeline();

  function setStage(index) {
    if (index === activeStage) return;
    activeStage = index;

    var stage = chainStages[index];
    if (chainState && stage) {
      chainState.textContent = stage.getAttribute('data-stage-name') || '';
    }

    chainStages.forEach(function (el, i) {
      el.classList.toggle('is-current', i === index);
    });

    var next = chainMap[index] || [];
    chainNodeEls.forEach(function (el) {
      var name = el.getAttribute('data-node');
      var on = next.indexOf(name) !== -1;
      el.classList.toggle('is-active', on);
      if (on && activeNodes.indexOf(el) === -1) activeNodes.push(el);
    });
    activeNodes = activeNodes.filter(function (el) {
      if (next.indexOf(el.getAttribute('data-node')) === -1) {
        el.classList.remove('is-active');
        return false;
      }
      return true;
    });
  }

  var pulseLength = 0;
  if (chainPulsePath && typeof chainPulsePath.getTotalLength === 'function') {
    try { pulseLength = chainPulsePath.getTotalLength(); } catch (err) { pulseLength = 0; }
  }

  function updateChain() {
    if (!chainSection || !chainStages.length) return;

    var viewport = window.innerHeight || 800;
    var rect = chainSection.getBoundingClientRect();
    var top = rect.top;
    var visible = rect.bottom > -80 && top < viewport + 80;

    var focusLine = viewport * 0.52;
    var index = 0;
    for (var i = 0; i < chainStages.length; i += 1) {
      if (chainStages[i].getBoundingClientRect().top <= focusLine) index = i;
    }
    setStage(index);

    var local = clamp((focusLine - top) / Math.max(1, rect.height), 0, 1);

    if (!hasScrollTimeline && chainFill) {
      chainFill.style.transform = 'scaleX(' + local.toFixed(4) + ')';
    }

    if (!pulseLength || !chainPulse || !chainPulseGlow) return;

    if (!visible) {
      chainPulse.setAttribute('opacity', '0');
      chainPulseGlow.setAttribute('opacity', '0');
      return;
    }

    try {
      var point = chainPulsePath.getPointAtLength(pulseLength * local);
      chainPulse.setAttribute('cx', point.x.toFixed(2));
      chainPulse.setAttribute('cy', point.y.toFixed(2));
      chainPulseGlow.setAttribute('cx', point.x.toFixed(2));
      chainPulseGlow.setAttribute('cy', point.y.toFixed(2));
      var fade = local > 0.005 && local < 0.995 ? 1 : 0;
      chainPulse.setAttribute('opacity', String(fade));
      chainPulseGlow.setAttribute('opacity', String(fade ? 0.9 : 0));
    } catch (err) {
      /* geometry unavailable: keep the static diagram */
    }
  }

  /* ---------------------------------------------------------------------
     5. Hero camera choreography lives in motion.js.
     --------------------------------------------------------------------- */

  /* ---------------------------------------------------------------------
     6. Scroll loop
     --------------------------------------------------------------------- */
  var ticking = false;

  function onScrollFrame() {
    ticking = false;
    var y = window.pageYOffset || docEl.scrollTop || 0;
    updateHeaderAndProgress();
    updateNavHighlight();
    updateChain();
  }

  function requestScroll() {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(onScrollFrame);
  }

  window.addEventListener('scroll', requestScroll, { passive: true });
  window.addEventListener('resize', requestScroll, { passive: true });

  if (reduceQuery) {
    if (reduceQuery.addEventListener) {
      reduceQuery.addEventListener('change', function () {
        requestScroll();
      });
    } else if (reduceQuery.addListener) {
      reduceQuery.addListener(function () { requestScroll(); });
    }
  }

  /* ---------------------------------------------------------------------
     7. Copy buttons (SHA-256, xattr command)
     --------------------------------------------------------------------- */
  var copyStatus = document.getElementById('copyStatus');

  function announce(message) {
    if (!copyStatus) return;
    copyStatus.textContent = message;
  }

  function copyText(text) {
    return new Promise(function (resolve, reject) {
      if (navigator.clipboard && window.isSecureContext !== false) {
        navigator.clipboard.writeText(text).then(resolve).catch(function () {
          legacyCopy(text).then(resolve).catch(reject);
        });
        return;
      }
      legacyCopy(text).then(resolve).catch(reject);
    });
  }

  function legacyCopy(text) {
    return new Promise(function (resolve, reject) {
      var area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.top = '-2000px';
      area.style.left = '0';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      area.setSelectionRange(0, area.value.length);
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
      document.body.removeChild(area);
      if (ok) resolve();
      else reject(new Error('copy unavailable'));
    });
  }

  function selectElementText(el) {
    try {
      var range = document.createRange();
      range.selectNodeContents(el);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    } catch (err) {
      /* ignore */
    }
  }

  $all('.copy-btn').forEach(function (button) {
    var original = button.querySelector('span');
    var label = original ? original.textContent : '复制';
    var timer = null;

    button.addEventListener('click', function () {
      var target = document.getElementById(button.getAttribute('data-copy-target') || '');
      if (!target) return;
      var text = (target.textContent || '').trim();
      if (!text) return;

      copyText(text).then(function () {
        announce('已复制到剪贴板');
        if (original) original.textContent = '已复制';
        button.classList.add('is-copied');
      }).catch(function () {
        announce('自动复制不可用，请手动选择文本');
        if (original) original.textContent = '请手动复制';
        selectElementText(target);
      }).then(function () {
        window.clearTimeout(timer);
        timer = window.setTimeout(function () {
          if (original) original.textContent = label;
          button.classList.remove('is-copied');
        }, 2200);
      });
    });
  });

  /* ---------------------------------------------------------------------
     8. Latest release.json override (built-in values stay if unavailable)
     --------------------------------------------------------------------- */
  function formatSize(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes) || bytes <= 0) return '';
    return (bytes / 1000000).toFixed(1) + ' MB';
  }

  function formatBytes(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes)) return '';
    try { return bytes.toLocaleString('en-US'); } catch (err) { return String(bytes); }
  }

  function setText(selector, value) {
    if (!value) return;
    $all(selector).forEach(function (el) { el.textContent = value; });
  }

  function applyRelease(data) {
    if (!data || typeof data !== 'object') return;

    if (typeof data.version === 'string' && data.version) {
      var label = data.version.charAt(0).toLowerCase() === 'v' ? data.version : 'v' + data.version;
      setText('[data-version]', label);
    }

    if (typeof data.download_url === 'string' && /^https?:/.test(data.download_url)) {
      $all('[data-download]').forEach(function (link) {
        link.setAttribute('href', data.download_url);
      });
    }

    if (typeof data.sha256 === 'string' && /^[a-fA-F0-9]{64}$/.test(data.sha256)) {
      $all('[data-sha]').forEach(function (el) {
        el.textContent = data.sha256.toLowerCase();
        el.setAttribute('data-sha', data.sha256.toLowerCase());
      });
    }

    if (typeof data.size === 'number') {
      setText('[data-size]', formatSize(data.size));
      setText('[data-bytes]', formatBytes(data.size));
    }

    if (typeof data.published_at === 'string' && data.published_at.length >= 10) {
      setText('[data-date]', data.published_at.slice(0, 10));
    }
  }

  /* 版本号来源（按可信度与可用性取最高版本）：
       1. 站点同目录 latest.json —— 随站点一起部署，sha256 与安装包同源；
       2. 仓库 main 分支的 latest.json（raw.githubusercontent.com，支持跨域）；
       3. jsDelivr 镜像（国内访问更稳，同样跨域可读）。
     三者并行取回，按语义版本号取最高的那份整体应用；任一失败静默忽略，
     页面保留内置准确值。注意：github.com/.../releases/latest/download/... 不带
     跨域头，浏览器直接读会被拦（已实测 Failed to fetch），所以不采用。 */
  function versionParts(value) {
    if (typeof value !== 'string') return null;
    var chunks = value.replace(/^v/i, '').split(/[.\-+]/);
    var nums = [];
    for (var i = 0; i < chunks.length; i += 1) {
      var n = parseInt(chunks[i], 10);
      if (!isFinite(n)) break;
      nums.push(n);
    }
    return nums.length ? nums : null;
  }

  function compareVersion(a, b) {
    var left = versionParts(a);
    var right = versionParts(b);
    if (!left || !right) return 0;
    var len = Math.max(left.length, right.length);
    for (var i = 0; i < len; i += 1) {
      var x = left[i] || 0;
      var y = right[i] || 0;
      if (x !== y) return x > y ? 1 : -1;
    }
    return 0;
  }

  function fetchRelease(url) {
    return window.fetch(url, { cache: 'no-store', credentials: 'omit' })
      .then(function (response) {
        if (!response.ok) throw new Error('release source ' + response.status);
        return response.json();
      })
      .catch(function () {
        return null;
      });
  }

  var RELEASE_SOURCES = [
    'latest.json',
    'https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json',
    'https://cdn.jsdelivr.net/gh/BH2VOQ/RLPlayer-Mac@main/latest.json'
  ];

  if (typeof window.fetch === 'function') {
    Promise.all(RELEASE_SOURCES.map(fetchRelease)).then(function (results) {
      var best = null;
      results.forEach(function (data) {
        if (!data || typeof data !== 'object' || typeof data.version !== 'string') return;
        if (!best || compareVersion(data.version, best.version) > 0) best = data;
      });
      if (best) applyRelease(best);
    }).catch(function () {
      /* file:// or offline: keep the accurate built-in values */
    });
  }

  /* ---------------------------------------------------------------------
     9. Screenshot placeholders: hide cleanly when the asset is absent
     --------------------------------------------------------------------- */
  $all('img[data-shot]').forEach(function (img) {
    function markMissing() {
      var frame = img.closest ? img.closest('[data-shot-frame]') : null;
      if (frame) frame.classList.add('is-missing');
    }
    if (img.complete && img.naturalWidth === 0) markMissing();
    img.addEventListener('error', markMissing);
  });

  /* ---------------------------------------------------------------------
     10. Footer year + boot
     --------------------------------------------------------------------- */
  var yearEl = document.getElementById('year');
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

  if (chainStages.length) {
    setStage(-1);
    setStage(0);
  }
  onScrollFrame();
})();
