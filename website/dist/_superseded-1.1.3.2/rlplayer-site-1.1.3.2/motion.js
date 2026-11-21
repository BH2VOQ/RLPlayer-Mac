/* RLPlayer — scroll choreography and spectral motion.
   Dependency-free, DPR-aware, paused offscreen, reduced-motion safe. */
(function () {
  'use strict';

  var doc = document.documentElement;
  var reduceQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
  var finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');
  var $ = function (selector, scope) { return (scope || document).querySelector(selector); };
  var $$ = function (selector, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(selector)); };
  var clamp = function (value, min, max) { return Math.min(max, Math.max(min, value)); };
  var lerp = function (from, to, amount) { return from + (to - from) * amount; };
  var reduced = reduceQuery.matches;
  var scrollY = window.pageYOffset || 0;
  var viewportH = window.innerHeight || 800;
  var viewportW = window.innerWidth || 1200;
  var hero = $('.hero');
  var heroInner = $('.hero__inner');
  var heroShot = $('[data-hero-scene]');
  var heroGrid = $('.hero__grid');
  var chain = $('#signal');
  var heroInView = true;
  var chainInView = false;

  /* -----------------------------------------------------------------------
     Spectral field: three precision waveforms plus a sampled bit constellation.
     This is deliberately abstract artwork, never a fabricated application UI.
     ----------------------------------------------------------------------- */
  var canvas = $('#heroWave');
  var context = canvas ? canvas.getContext('2d') : null;
  var canvasW = 0;
  var canvasH = 0;
  var canvasDpr = 1;
  var pointerTarget = 0.5;
  var pointerX = 0.5;

  function resizeCanvas() {
    if (!canvas || !context) return;
    var rect = canvas.getBoundingClientRect();
    canvasDpr = Math.min(window.devicePixelRatio || 1, 2);
    canvasW = Math.max(1, rect.width);
    canvasH = Math.max(1, rect.height);
    canvas.width = Math.round(canvasW * canvasDpr);
    canvas.height = Math.round(canvasH * canvasDpr);
    context.setTransform(canvasDpr, 0, 0, canvasDpr, 0, 0);
  }

  function waveY(x, lane, time) {
    var center = canvasH * (lane === 0 ? 0.37 : lane === 1 ? 0.45 : 0.54);
    var normalized = x / Math.max(1, canvasW);
    var envelope = Math.pow(Math.sin(normalized * Math.PI), 1.5);
    var pointerFocus = Math.exp(-Math.pow(normalized - pointerX, 2) / 0.018);
    var frequency = lane === 0 ? 0.018 : lane === 1 ? 0.026 : 0.011;
    var amplitude = (lane === 0 ? 28 : lane === 1 ? 15 : 40) * envelope;
    var phase = time * (lane === 1 ? -0.00042 : 0.00034) + lane * 1.8;
    var signal = Math.sin(x * frequency + phase) * 0.72 + Math.sin(x * frequency * 0.43 - phase * 1.3) * 0.28;
    return center + signal * amplitude * (1 + pointerFocus * 0.48);
  }

  function drawSpectralField(time) {
    if (!context || !canvasW || !canvasH) return;
    context.clearRect(0, 0, canvasW, canvasH);
    pointerX = reduced ? pointerTarget : lerp(pointerX, pointerTarget, 0.045);

    var gradient = context.createLinearGradient(0, 0, canvasW, 0);
    gradient.addColorStop(0, 'rgba(24, 24, 27, 0)');
    gradient.addColorStop(0.2, 'rgba(82, 82, 91, 0.16)');
    gradient.addColorStop(0.52, 'rgba(217, 45, 62, 0.28)');
    gradient.addColorStop(0.8, 'rgba(82, 82, 91, 0.15)');
    gradient.addColorStop(1, 'rgba(24, 24, 27, 0)');

    for (var lane = 0; lane < 3; lane += 1) {
      context.beginPath();
      for (var x = 0; x <= canvasW; x += 4) {
        var y = waveY(x, lane, time);
        if (x === 0) context.moveTo(x, y);
        else context.lineTo(x, y);
      }
      context.strokeStyle = gradient;
      context.lineWidth = lane === 0 ? 1.15 : 0.72;
      context.globalAlpha = lane === 0 ? 0.86 : 0.48;
      context.stroke();
    }

    context.globalAlpha = 1;
    var baseline = canvasH * 0.63;
    var step = Math.max(12, Math.floor(canvasW / 96));
    for (var sx = step; sx < canvasW; sx += step) {
      var unit = sx / canvasW;
      var envelope = Math.pow(Math.sin(unit * Math.PI), 1.2);
      var harmonic = Math.abs(Math.sin(sx * 0.026 + time * 0.00025) * 0.62 + Math.sin(sx * 0.009 - time * 0.00018) * 0.38);
      var height = 4 + harmonic * envelope * 56;
      var alpha = 0.035 + envelope * 0.11;
      context.strokeStyle = 'rgba(39, 39, 42,' + alpha.toFixed(3) + ')';
      context.lineWidth = 1;
      context.beginPath();
      context.moveTo(sx + 0.5, baseline - height);
      context.lineTo(sx + 0.5, baseline + height);
      context.stroke();
      if ((sx / step) % 4 === 0) {
        context.fillStyle = 'rgba(217, 45, 62,' + (alpha * 1.35).toFixed(3) + ')';
        context.fillRect(sx - 1, baseline - height - 3, 2, 2);
      }
    }
  }

  if (hero && !reduced) {
    hero.addEventListener('pointermove', function (event) {
      pointerTarget = clamp(event.clientX / Math.max(1, viewportW), 0, 1);
    }, { passive: true });
    hero.addEventListener('pointerleave', function () { pointerTarget = 0.5; }, { passive: true });
  }

  /* -----------------------------------------------------------------------
     Hero camera: the real screenshot rises out of a 3D plane as it enters.
     Pointer tilt is spring-damped and limited to a hardware-like 1.4 degrees.
     ----------------------------------------------------------------------- */
  var heroTilt = { x: 0, y: 0, tx: 0, ty: 0, vx: 0, vy: 0 };
  if (heroShot && finePointer.matches) {
    heroShot.addEventListener('pointermove', function (event) {
      if (reduced) return;
      var rect = heroShot.getBoundingClientRect();
      var px = clamp((event.clientX - rect.left) / rect.width, 0, 1) - 0.5;
      var py = clamp((event.clientY - rect.top) / rect.height, 0, 1) - 0.5;
      heroTilt.tx = py * -1.1;
      heroTilt.ty = px * 1.4;
    }, { passive: true });
    heroShot.addEventListener('pointerleave', function () {
      heroTilt.tx = 0;
      heroTilt.ty = 0;
    }, { passive: true });
  }

  function springValue(state, key, targetKey, velocityKey) {
    var force = (state[targetKey] - state[key]) * 0.085;
    state[velocityKey] = (state[velocityKey] + force) * 0.72;
    state[key] += state[velocityKey];
  }

  function updateHeroCamera() {
    if (!hero || !heroShot) return;
    if (reduced || heroShot.classList.contains('is-missing')) {
      heroShot.style.transform = '';
      if (heroInner) { heroInner.style.transform = ''; heroInner.style.opacity = ''; }
      return;
    }
    var heroTop = hero.offsetTop || 0;
    var sceneDocumentTop = heroTop + heroShot.offsetTop;
    var sceneTop = sceneDocumentTop - scrollY;
    var enter = clamp((viewportH - sceneTop) / Math.max(1, viewportH * 0.76), 0, 1);
    var eased = 1 - Math.pow(1 - enter, 3);
    var exit = clamp((scrollY - sceneDocumentTop) / Math.max(1, viewportH), 0, 1);
    var rotate = (1 - eased) * 11;
    var scale = 0.905 + eased * 0.095;
    var translate = (1 - eased) * 64 - exit * 18;

    springValue(heroTilt, 'x', 'tx', 'vx');
    springValue(heroTilt, 'y', 'ty', 'vy');
    heroShot.style.transform = 'translate3d(0,' + translate.toFixed(2) + 'px,0) perspective(1600px) rotateX(' + (rotate + heroTilt.x).toFixed(3) + 'deg) rotateY(' + heroTilt.y.toFixed(3) + 'deg) scale(' + scale.toFixed(4) + ')';

    if (heroInner) {
      var recede = clamp(scrollY / Math.max(1, viewportH * 0.9), 0, 1);
      heroInner.style.transform = 'translate3d(0,' + (-recede * 32).toFixed(2) + 'px,0)';
      heroInner.style.opacity = String(1 - recede * 0.26);
    }
    if (heroGrid) {
      heroGrid.style.transform = 'translate3d(-50%,' + (scrollY * 0.045).toFixed(2) + 'px,0)';
    }
  }

  /* -----------------------------------------------------------------------
     Two independent light lanes follow the actual SVG geometry of DirectSDM
     and 64-bit DSP. Their intensity follows the active narrative chapter.
     ----------------------------------------------------------------------- */
  var chainSvg = $('.chain-svg');
  var chainStages = $$('.chain-stage');
  var particles = [];
  var svgNS = 'http://www.w3.org/2000/svg';

  function makeSignalLane(pathData, kind, count) {
    if (!chainSvg) return;
    var geometry = document.createElementNS(svgNS, 'path');
    geometry.setAttribute('d', pathData);
    geometry.setAttribute('fill', 'none');
    geometry.setAttribute('stroke', 'none');
    geometry.setAttribute('aria-hidden', 'true');
    geometry.style.pointerEvents = 'none';
    chainSvg.appendChild(geometry);
    var length = 0;
    try { length = geometry.getTotalLength(); } catch (error) { return; }
    for (var i = 0; i < count; i += 1) {
      var dot = document.createElementNS(svgNS, 'circle');
      dot.setAttribute('r', String(1.8 + (i % 3) * 0.45));
      dot.setAttribute('class', 'signal-particle');
      dot.setAttribute('opacity', '0');
      chainSvg.appendChild(dot);
      particles.push({ dot: dot, path: geometry, length: length, offset: i / count, kind: kind });
    }
  }

  if (chainSvg) {
    makeSignalLane('M220 84 C220 102 124 96 124 120 L124 372 C124 384 180 388 220 396', 'direct', 7);
    makeSignalLane('M220 84 C220 102 316 96 316 120 L316 330 L316 372 C316 384 260 388 220 396', 'dsp', 9);
  }

  function updateSignalLanes(time) {
    if (reduced || !particles.length || !chainInView) return;
    var active = 0;
    chainStages.forEach(function (stage, index) { if (stage.classList.contains('is-current')) active = index; });
    particles.forEach(function (particle) {
      var phase = (time * 0.000075 + particle.offset) % 1;
      var point = particle.path.getPointAtLength(particle.length * phase);
      var emphasis = active === 0 || active === 3 ? 0.24 : active === 1 && particle.kind === 'direct' ? 0.92 : active === 2 && particle.kind === 'dsp' ? 0.92 : 0.07;
      var envelope = Math.sin(phase * Math.PI);
      particle.dot.setAttribute('cx', point.x.toFixed(2));
      particle.dot.setAttribute('cy', point.y.toFixed(2));
      particle.dot.setAttribute('opacity', (emphasis * envelope).toFixed(3));
    });
  }

  /* -----------------------------------------------------------------------
     Measured-value counters. Scientific notation remains static; only readable
     decimal/count metrics animate, with their original units and formatting.
     ----------------------------------------------------------------------- */
  var counters = [];
  var counterObserver = null;

  function startCounter(el) {
    var textNode = el.firstChild;
    if (!textNode || textNode.nodeType !== 3) return;
    var original = textNode.nodeValue.trim();
    if (!/^−?[0-9,]+(?:\.[0-9]+)?$/.test(original)) return;
    var target = Number(original.replace('−', '-').replace(/,/g, ''));
    if (!isFinite(target)) return;
    var decimals = original.indexOf('.') === -1 ? 0 : original.split('.')[1].length;
    var grouped = original.indexOf(',') !== -1;
    var trailing = /\s$/.test(textNode.nodeValue) ? ' ' : '';
    counters.push({ el: el, node: textNode, target: target, decimals: decimals, grouped: grouped, trailing: trailing, start: performance.now(), duration: 1350 + Math.min(600, Math.abs(target) / 2000) });
    textNode.nodeValue = original.replace(/−?[0-9,]+(?:\.[0-9]+)?/, '0');
  }

  function updateCounters(now) {
    for (var i = counters.length - 1; i >= 0; i -= 1) {
      var counter = counters[i];
      var progress = clamp((now - counter.start) / counter.duration, 0, 1);
      var eased = progress === 1 ? 1 : 1 - Math.pow(2, -10 * progress);
      var value = counter.target * eased;
      var output = Math.abs(value).toFixed(counter.decimals);
      if (counter.grouped) output = Number(output).toLocaleString('en-US', { minimumFractionDigits: counter.decimals, maximumFractionDigits: counter.decimals });
      counter.node.nodeValue = (value < 0 ? '−' : '') + output + counter.trailing;
      if (progress === 1) counters.splice(i, 1);
    }
  }

  if ('IntersectionObserver' in window && !reduced) {
    counterObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        startCounter(entry.target);
        counterObserver.unobserve(entry.target);
      });
    }, { threshold: 0.55 });
    $$('.metric__num, .metric__aside-num').forEach(function (el) { counterObserver.observe(el); });
  }

  /* -----------------------------------------------------------------------
     Bento specular tracking and damped tilt. No perpetual layout animation:
     only transform/opacity change and offscreen scenes skip their canvas work.
     ----------------------------------------------------------------------- */
  var tiltCards = $$('.card, .vcard').map(function (card) {
    return { el: card, x: 0, y: 0, tx: 0, ty: 0, vx: 0, vy: 0, active: false };
  });

  if (finePointer.matches) {
    tiltCards.forEach(function (state) {
      var card = state.el;
      card.addEventListener('pointermove', function (event) {
        if (reduced) return;
        var rect = card.getBoundingClientRect();
        var px = clamp(event.clientX - rect.left, 0, rect.width);
        var py = clamp(event.clientY - rect.top, 0, rect.height);
        card.style.setProperty('--mx', (px / rect.width * 100).toFixed(1) + '%');
        card.style.setProperty('--my', (py / rect.height * 100).toFixed(1) + '%');
        state.tx = ((py / rect.height) - 0.5) * -1.15;
        state.ty = ((px / rect.width) - 0.5) * 1.35;
        state.active = true;
      }, { passive: true });
      card.addEventListener('pointerleave', function () {
        state.tx = 0;
        state.ty = 0;
      }, { passive: true });
    });
  }

  function updateTiltCards() {
    if (!finePointer.matches) return;
    tiltCards.forEach(function (state) {
      if (reduced) { state.el.style.transform = ''; return; }
      springValue(state, 'x', 'tx', 'vx');
      springValue(state, 'y', 'ty', 'vy');
      var settled = Math.abs(state.x) + Math.abs(state.y) + Math.abs(state.vx) + Math.abs(state.vy) < 0.002 && state.tx === 0 && state.ty === 0;
      if (settled) {
        if (state.active) { state.el.style.transform = ''; state.active = false; }
        return;
      }
      state.el.style.transform = 'perspective(1200px) rotateX(' + state.x.toFixed(3) + 'deg) rotateY(' + state.y.toFixed(3) + 'deg) translate3d(0,-2px,0)';
    });
  }

  var visibilityObserver = null;
  if ('IntersectionObserver' in window) {
    visibilityObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.target === hero) heroInView = entry.isIntersecting;
        if (entry.target === chain) chainInView = entry.isIntersecting;
      });
    }, { rootMargin: '120px 0px' });
    if (hero) visibilityObserver.observe(hero);
    if (chain) visibilityObserver.observe(chain);
  } else {
    chainInView = true;
  }

  function frame(now) {
    if (!document.hidden) {
      if (heroInView) drawSpectralField(reduced ? 0 : now);
      updateHeroCamera();
      updateSignalLanes(now);
      updateCounters(now);
      updateTiltCards();
    }
    if (!reduced) window.requestAnimationFrame(frame);
  }

  function onScroll() { scrollY = window.pageYOffset || doc.scrollTop || 0; }
  function onResize() {
    scrollY = window.pageYOffset || doc.scrollTop || 0;
    viewportH = window.innerHeight || 800;
    viewportW = window.innerWidth || 1200;
    resizeCanvas();
    if (reduced) drawSpectralField(0);
  }

  /* -----------------------------------------------------------------------
     Hero 3-view real screenshot switcher.
     ----------------------------------------------------------------------- */
  var heroTabs = $$('.hero-shot__tab');
  var heroMainImg = $('#heroMainImg');
  var heroShotCaption = $('#heroShotCaption');
  if (heroTabs.length && heroMainImg) {
    heroTabs.forEach(function (tab) {
      tab.addEventListener('click', function () {
        var nextSrc = tab.getAttribute('data-hero-src');
        var nextCap = tab.getAttribute('data-hero-caption');
        if (!nextSrc) return;
        heroTabs.forEach(function (t) {
          var active = t === tab;
          t.classList.toggle('is-active', active);
          t.setAttribute('aria-selected', active ? 'true' : 'false');
        });
        if (heroMainImg.getAttribute('src') !== nextSrc) {
          heroMainImg.classList.add('is-switching');
          window.setTimeout(function () {
            heroMainImg.setAttribute('src', nextSrc);
            if (heroShotCaption && nextCap) heroShotCaption.textContent = nextCap;
            heroMainImg.classList.remove('is-switching');
          }, 90);
        }
      });
    });
  }

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onResize, { passive: true });
  reduceQuery.addEventListener('change', function (event) {
    reduced = event.matches;
    if (reduced) {
      counters.forEach(function (counter) {
        var finalValue = Math.abs(counter.target).toFixed(counter.decimals);
        if (counter.grouped) finalValue = Number(finalValue).toLocaleString('en-US', { minimumFractionDigits: counter.decimals, maximumFractionDigits: counter.decimals });
        counter.node.nodeValue = (counter.target < 0 ? '−' : '') + finalValue + counter.trailing;
      });
      counters.length = 0;
      particles.forEach(function (particle) { particle.dot.setAttribute('opacity', '0'); });
      if (heroShot) heroShot.style.transform = '';
      drawSpectralField(0);
    } else {
      window.requestAnimationFrame(frame);
    }
  });

  resizeCanvas();
  onScroll();
  updateHeroCamera();
  drawSpectralField(0);
  if (!reduced) window.requestAnimationFrame(frame);
})();
