// html/app.js — VP Chopshop Dismantle Minigame NUI Controller
(function() {
  const app = document.getElementById('dismantle-app');
  const hudTitle = document.getElementById('hud-title');
  const hudHelp = document.getElementById('hud-help');
  const hotspotContainer = document.getElementById('hotspot-container');
  const overallProgressText = document.getElementById('overall-progress-text');
  const overallProgressFill = document.getElementById('overall-progress-fill');

  const CIRCLE_RADIUS = 26;
  const CIRCLE_CIRCUMFERENCE = 2 * Math.PI * CIRCLE_RADIUS; // ~163.36

  // [PR-4] primitive 'strike' — anel que fecha de STRIKE_R_MAX -> STRIKE_R_MIN e
  // volta (onda triangular). Acerto se o raio do anel estiver na faixa STRIKE_BAND
  // no momento do clique. Erro não pune progresso.
  const STRIKE_R_MAX = 24;
  const STRIKE_R_MIN = 5;
  const STRIKE_BAND = [8.5, 14.5];
  const STRIKE_CYCLE_MS = 850;
  let strikeRaf = null;
  let _serialSander = null;  // [VISUAL-01B] <img> da lixa que segue o cursor

  function showSander(x, y) {
    if (!_serialSander || _serialSander.dataset.ok !== '1') return;
    _serialSander.hidden = false;
    _serialSander.style.left = x + 'px';
    _serialSander.style.top = y + 'px';
  }
  function hideSander() { if (_serialSander) _serialSander.hidden = true; }

  let activeMinigame = false;
  let pointsMap = {};
  let activeHotspotId = null;
  let prevMouseAngle = 0;
  let uxSpeedMult = 1.0;
  let traceTolerancePx = 55.0;
  let cutTimer = null;
  let lastCutTimestamp = 0;

  function postNui(event, data = {}) {
    const resourceName = window.GetParentResourceName ? window.GetParentResourceName() : 'vp_chopshop';
    fetch(`https://${resourceName}/${event}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data)
    }).catch(() => {});
  }

  function completePoint(pt) {
    if (pt.completed) return;
    pt.completed = true;
    pt.progress = 100;

    if (pt.primitive === 'trace') {
      if (pt.fgPath) {
        pt.fgPath.style.strokeDashoffset = 0;
      }
      if (pt.torchTip) {
        pt.torchTip.classList.add('hidden');
      }
      if (pt.startNode) {
        pt.startNode.classList.add('completed');
        const icon = pt.startNode.querySelector('.trace-icon');
        if (icon) icon.innerHTML = '&#10003;';
      }
      pt.isTracing = false;

      // Ocultar imediatamente a seção cortada da tela
      if (pt.element) {
        pt.element.style.display = 'none';
      }
    } else {
      if (pt.progressCircle) {
        pt.progressCircle.style.strokeDashoffset = 0;
      }
      if (typeof pt.onProgress === 'function') pt.onProgress(100);
      if (pt.visualType === 'exhaust_bolt') {
        // [VISUAL-01] feedback = parafuso sai + furo aparece (não usa ✓)
        finishExhaustBoltVisual(pt);
      } else if (pt.icon) {
        pt.icon.innerHTML = '&#10003;';
      }
      if (pt.primitive === 'sand') hideSander();
      if (_catPanelActive) { catUpdateTool(); catCheckOpen(); }
    }

    if (pt.element && pt.primitive !== 'trace') {
      pt.element.classList.remove('active', 'cutting', 'drilling', 'tracing', 'sanding');
      pt.element.classList.add('completed');
    }

    postNui('minigamePointComplete', { id: pt.id });
    activeHotspotId = null;
    stopCuttingLoop();
    updateOverallProgress();

    // [FIX-1.3] Se completar este ponto acabou de destravar um 'strike' (ex.: golpes
    // de marreta liberados após tirar as porcas), leva a câmera até ele — senão o
    // ponto fica fora de quadro e o jogador não consegue clicar.
    if (pt.primitive !== 'trace') {
      for (const k in pointsMap) {
        const nx = pointsMap[k];
        if (nx && nx.primitive === 'strike' && !nx.completed && !nx._focused && isPointUnlocked(nx)) {
          nx._focused = true;
          setTimeout(() => {
            if (activeMinigame && !nx.completed) postNui('minigamePointStart', { id: nx.id });
          }, 350);
          break;
        }
      }
    }

    // [UX-E Auto-Advance] Segue automaticamente para o próximo corte na carcaça
    if (pt.primitive === 'trace') {
      const allKeys = Object.keys(pointsMap);
      let nextPt = null;
      for (const k of allKeys) {
        const candidate = pointsMap[k];
        if (candidate && candidate.primitive === 'trace' && !candidate.completed && candidate.id !== pt.id) {
          nextPt = candidate;
          break;
        }
      }

      if (nextPt) {
        setTimeout(() => {
          if (!activeMinigame || nextPt.completed) return;
          activeHotspotId = nextPt.id;
          postNui('minigamePointStart', { id: nextPt.id });
        }, 400);
      }
    }
  }

  function startCuttingLoop(ptId) {
    stopCuttingLoop();
    lastCutTimestamp = performance.now();

    function cutTick(now) {
      if (!activeMinigame || activeHotspotId !== ptId) {
        stopCuttingLoop();
        return;
      }
      const pt = pointsMap[ptId];
      if (!pt || pt.completed) {
        stopCuttingLoop();
        return;
      }

      const deltaMs = now - lastCutTimestamp;
      lastCutTimestamp = now;

      // Rate of progress: 100% / totalDurationMs
      const durationMs = pt.holdTimeMs || 2000;
      const progressDelta = (deltaMs / durationMs) * 100 * uxSpeedMult;

      pt.progress = Math.min(100, pt.progress + progressDelta);
      const offset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
      pt.progressCircle.style.strokeDashoffset = offset;

      if (pt.progress >= 100) {
        completePoint(pt);
      } else {
        updateOverallProgress();
        cutTimer = requestAnimationFrame(cutTick);
      }
    }

    cutTimer = requestAnimationFrame(cutTick);
  }

  function stopCuttingLoop() {
    if (cutTimer) {
      cancelAnimationFrame(cutTimer);
      cutTimer = null;
    }
  }

  // ─── [PR-4] Strike primitive (timing-click com anel que fecha) ──────────────
  function strikeLoop(now) {
    if (!activeMinigame) { strikeRaf = null; return; }
    let anyStrike = false;
    for (const k in pointsMap) {
      const pt = pointsMap[k];
      if (!pt || pt.primitive !== 'strike' || !pt.closerCircle) continue;
      if (pt.completed) { pt.closerCircle.style.display = 'none'; continue; }
      anyStrike = true;
      if (!isPointUnlocked(pt)) { pt.closerCircle.style.display = 'none'; continue; }
      pt.closerCircle.style.display = '';
      if (pt._t0 == null) pt._t0 = now;
      const phase = ((now - pt._t0) % STRIKE_CYCLE_MS) / STRIKE_CYCLE_MS; // 0..1
      const tri = phase < 0.5 ? (phase * 2) : (2 - phase * 2);            // 0->1->0
      pt._closerR = STRIKE_R_MAX - tri * (STRIKE_R_MAX - STRIKE_R_MIN);
      pt.closerCircle.setAttribute('r', pt._closerR.toFixed(1));
      const inBand = pt._closerR >= STRIKE_BAND[0] && pt._closerR <= STRIKE_BAND[1];
      pt.closerCircle.classList.toggle('in-band', inBand);
    }
    strikeRaf = anyStrike ? requestAnimationFrame(strikeLoop) : null;
  }

  function stopStrikeLoop() {
    if (strikeRaf) { cancelAnimationFrame(strikeRaf); strikeRaf = null; }
  }

  function completedCountNow() {
    let n = 0;
    for (const k in pointsMap) { if (pointsMap[k] && pointsMap[k].completed) n++; }
    return n;
  }

  // [FIX-1.2/1.3] Gate de destravamento de ponto:
  //   lockUntilOthers → só libera quando todos os pontos SEM o flag estão completos.
  //   unlockAfter (int) → só libera após N outros pontos completos (sequência).
  function isPointUnlocked(pt) {
    if (!pt) return true;
    if (typeof pt.unlockAfter === 'number' && pt.unlockAfter > 0) {
      if (completedCountNow() < pt.unlockAfter) return false;
    }
    if (pt.lockUntilOthers) {
      for (const k in pointsMap) {
        const o = pointsMap[k];
        if (o && !o.lockUntilOthers && !o.completed) return false;
      }
    }
    return true;
  }

  function isPointGated(pt) {
    return !!pt && ((typeof pt.unlockAfter === 'number' && pt.unlockAfter > 0) || pt.lockUntilOthers);
  }

  function refreshLockedPoints() {
    for (const k in pointsMap) {
      const pt = pointsMap[k];
      if (!pt || !isPointGated(pt) || pt.completed) continue;
      const unlocked = isPointUnlocked(pt);
      if (pt.element) pt.element.classList.toggle('locked', !unlocked);
    }
  }

  // ─── [VISUAL-01] Overlay fotorrealista de fixação (parafuso do escapamento) ──
  // Renderer COMUM aos profiles catalytic / bench_catalytic. Os pontos só enviam
  // visualType='exhaust_bolt'. Sem RAF próprio: o estado visual é atualizado no
  // mesmo mousemove que já mexe em pt.progress / pt.accumulatedDeg.
  const XBOLT_BASE = 'assets/minigame/catalytic/';
  const XBOLT_IMG = {
    hole:   'exhaust_bolt_hole.png',
    thread: 'exhaust_bolt_thread.png',
    washer: 'exhaust_washer.png',
    head:   'exhaust_bolt_head.png',
  };

  function buildExhaustBolt(el, ptRef) {
    const wrap = document.createElement('div');
    wrap.className = 'xbolt';
    wrap.innerHTML = `
      <img class="xbolt-layer xbolt-hole"   alt="" src="${XBOLT_BASE}${XBOLT_IMG.hole}">
      <img class="xbolt-layer xbolt-thread" alt="" src="${XBOLT_BASE}${XBOLT_IMG.thread}">
      <img class="xbolt-layer xbolt-washer" alt="" src="${XBOLT_BASE}${XBOLT_IMG.washer}">
      <img class="xbolt-layer xbolt-head"   alt="" src="${XBOLT_BASE}${XBOLT_IMG.head}">`;
    el.appendChild(wrap);
    // Fallback gracioso: se QUALQUER asset falhar, mantém o círculo genérico.
    let okCount = 0;
    wrap.querySelectorAll('img').forEach((img) => {
      img.addEventListener('load', () => {
        okCount += 1;
        if (okCount >= 4) el.classList.add('xbolt-ready');
      });
      img.addEventListener('error', () => {
        el.classList.remove('xbolt-ready');
        el.classList.add('xbolt-missing');
      });
    });
    ptRef._xhead   = wrap.querySelector('.xbolt-head');
    ptRef._xwasher = wrap.querySelector('.xbolt-washer');
    ptRef._xthread = wrap.querySelector('.xbolt-thread');
    ptRef._xwrap   = wrap;
  }

  function updateExhaustBoltVisual(pt) {
    const p = Math.max(0, Math.min(1, pt.progress / 100));
    if (pt._xhead) {
      pt._xhead.style.transform =
        `translateY(${(-p * 15).toFixed(1)}px) rotate(${(pt.accumulatedDeg || 0).toFixed(0)}deg)`;
    }
    if (pt._xwasher) {
      pt._xwasher.style.transform = `translateY(${(-p * 4).toFixed(1)}px)`;
    }
    if (pt._xthread) {
      // revela a rosca de cima p/ baixo conforme o parafuso sai
      pt._xthread.style.clipPath = `inset(${((1 - p) * 100).toFixed(0)}% 0 0 0)`;
      pt._xthread.style.opacity = (0.15 + p * 0.85).toFixed(2);
    }
  }

  function finishExhaustBoltVisual(pt) {
    if (!pt._xwrap) return;
    pt._xwrap.classList.add('xbolt-out');   // fly-out curto da cabeça/washer/rosca
    setTimeout(() => {
      if (pt._xwrap) pt._xwrap.classList.add('xbolt-done');  // só o furo visível
    }, 220);
  }

  function strikeAttempt(pt) {
    if (!pt || pt.completed || pt.primitive !== 'strike') return;
    if (!isPointUnlocked(pt)) {
      pt.element.classList.add('strike-miss');
      setTimeout(() => pt.element && pt.element.classList.remove('strike-miss'), 170);
      return;
    }
    const r = (typeof pt._closerR === 'number') ? pt._closerR : STRIKE_R_MAX;
    const inBand = r >= STRIKE_BAND[0] && r <= STRIKE_BAND[1];

    if (inBand) {
      pt.hits = (pt.hits || 0) + 1;
      pt.element.classList.remove('strike-miss');
      pt.element.classList.add('strike-armed');
      setTimeout(() => pt.element && pt.element.classList.remove('strike-armed'), 130);
      postNui('minigameStrikeHit', { id: pt.id });

      pt.progress = Math.min(100, (pt.hits / pt.hitsNeeded) * 100);
      if (pt.progressCircle) {
        pt.progressCircle.style.strokeDashoffset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
      }
      if (pt.hits >= pt.hitsNeeded) {
        completePoint(pt);
      } else {
        updateOverallProgress();
      }
    } else {
      pt.element.classList.remove('strike-armed');
      pt.element.classList.add('strike-miss');
      setTimeout(() => pt.element && pt.element.classList.remove('strike-miss'), 170);
    }
  }

  // [FIX-1.3] Número de série de peça (formato bloco de motor / plaqueta VIN).
  function genSerial() {
    const A = 'ABCDEFGHJKLMNPRSTUVWXYZ';
    const D = '0123456789';
    const pick = (s, n) => Array.from({ length: n }, () => s[Math.floor(Math.random() * s.length)]).join('');
    return `${pick(A, 1)}${pick(D, 1)}${pick(A, 1)}-${pick(D, 3)}-${pick(A, 2)}${pick(D, 4)}`;
  }

  // [FIX-1.3] Painel "peça na bancada": plaqueta de metal escovado com o nº de série
  // gravado; o jogador esfrega a lixa (gesto 'sand') sobre cada faixa até apagar.
  const SERIAL_BASE = 'assets/minigame/serial/';

  // [VISUAL-01C] Estado do "lixamento livre": a lixa (foto) segue o cursor pela
  // tela; segurando LMB e passando sobre o número, cada célula do serial vai
  // desgastando. Termina quando todas as células (mapeadas aos 2 pontos do
  // profile) chegam a 100.
  let _serialPanelActive = false;
  let _serialSanding = false;
  let _serialCells = [];       // { el, wear, done, ptId }
  let _serialPoints = {};      // ptId -> pointsMap entry
  let _serialStartFired = false;

  function serialCellRate() { return 3.4; }   // ganho por evento de mousemove sobre a célula

  function serialSandAt(cx, cy) {
    if (!_serialSanding) return;
    const R = 46;  // raio efetivo da lixa (px)
    let touched = false;
    for (const c of _serialCells) {
      if (c.done) continue;
      const r = c.el.getBoundingClientRect();
      const dx = Math.max(r.left - cx, 0, cx - r.right);
      const dy = Math.max(r.top - cy, 0, cy - r.bottom);
      if (dx * dx + dy * dy > R * R) continue;
      touched = true;
      c.wear = Math.min(100, c.wear + serialCellRate());
      c.el.style.setProperty('--w', (c.wear / 100).toFixed(3));
      if (c.wear >= 100) { c.done = true; c.el.classList.add('done'); }
    }
    if (!touched) return;
    if (!_serialStartFired) {
      _serialStartFired = true;
      const first = Object.keys(_serialPoints)[0];
      if (first) postNui('minigamePointStart', { id: first });
    }
    // progresso por ponto = média do desgaste das suas células
    for (const ptId in _serialPoints) {
      const pt = _serialPoints[ptId];
      if (pt.completed) continue;
      const mine = _serialCells.filter((c) => c.ptId === ptId);
      const avg = mine.length ? mine.reduce((s, c) => s + c.wear, 0) / mine.length : 0;
      pt.progress = Math.floor(avg);
      if (pt.onProgress) pt.onProgress(pt.progress);
      if (pt.progress >= 100) completePoint(pt);
    }
    updateOverallProgress();
  }

  function buildSerialPanel(root, points) {
    const serial = genSerial();
    root.hidden = false;
    root.innerHTML = `
      <div class="serial-part">
        <img class="serial-plate-photo" alt="" src="${SERIAL_BASE}serial_plate.png">
        <div class="serial-part-head">
          <span class="serial-part-tag">PEÇA APREENDIDA</span>
          <span class="serial-part-kind">CAR PARTS</span>
        </div>
        <div class="serial-plate">
          <span class="serial-rivet r1"></span><span class="serial-rivet r2"></span>
          <span class="serial-rivet r3"></span><span class="serial-rivet r4"></span>
          <div class="serial-plate-label">N&ordm; DE S&Eacute;RIE</div>
          <div class="serial-code" id="serial-code">${serial}</div>
          <div class="serial-cells" id="serial-cells"></div>
        </div>
        <div class="serial-hint">Segure o clique e passe a lixa sobre o n&uacute;mero at&eacute; apag&aacute;-lo</div>
      </div>
      <img class="serial-sander" alt="" src="${SERIAL_BASE}serial_sander.png" hidden>`;

    const partEl = root.querySelector('.serial-part');
    const plateImg = root.querySelector('.serial-plate-photo');
    const sanderImg = root.querySelector('.serial-sander');
    plateImg.addEventListener('load', () => partEl.classList.add('plate-photo-ok'));
    plateImg.addEventListener('error', () => partEl.classList.remove('plate-photo-ok'));
    sanderImg.addEventListener('load', () => { sanderImg.dataset.ok = '1'; });
    _serialSander = sanderImg;

    const codeEl = root.querySelector('#serial-code');
    const cellsWrap = root.querySelector('#serial-cells');

    // 2 pontos do profile → progresso (barra + estado). Sem lock: movimento livre.
    _serialPoints = {};
    points.forEach((pt, i) => {
      const ptId = pt.id || `serial_zone_${i}`;
      const entry = {
        id: ptId, primitive: 'sand', progress: 0, completed: false, visible: true,
        lockUntilOthers: false, unlockAfter: null,
        onProgress: (p) => {
          codeEl.style.setProperty('--wear' + (i + 1), (p / 100).toFixed(3));
          if (i === points.length - 1) codeEl.classList.toggle('scrubbed', p >= 100);
        },
      };
      pointsMap[ptId] = entry;
      _serialPoints[ptId] = entry;
    });

    // grade de células cobrindo o número; metade esquerda → ponto 1, direita → ponto 2
    const ptIds = Object.keys(_serialPoints);
    const N = 12;
    _serialCells = [];
    for (let k = 0; k < N; k++) {
      const cell = document.createElement('span');
      cell.className = 'serial-cell';
      cell.style.left = (k * (100 / N)) + '%';
      cell.style.width = (100 / N) + '%';
      cellsWrap.appendChild(cell);
      _serialCells.push({
        el: cell, wear: 0, done: false,
        ptId: ptIds[k < N / 2 ? 0 : Math.min(1, ptIds.length - 1)],
      });
    }

    _serialSanding = false;
    _serialStartFired = false;
    _serialPanelActive = true;
    stopStrikeLoop();
  }

  // ─── [VISUAL-02] Painel "catalisador na bancada" ────────────────────────────
  const CAT_BASE = 'assets/minigame/catalytic/';
  let _catPanelActive = false;
  let _catTool = null;      // <img> chave/marreta que segue o cursor
  let _catPartEl = null;

  function catUpdateTool() {
    if (!_catTool) return;
    const anyBoltPending = Object.keys(pointsMap).some(
      (k) => pointsMap[k].primitive === 'rotate' && !pointsMap[k].completed);
    _catTool.dataset.mode = anyBoltPending ? 'wrench' : 'hammer';
  }
  function catCheckOpen() {
    if (!_catPartEl) return;
    const done = Object.keys(pointsMap).every((k) => pointsMap[k].completed);
    if (done) _catPartEl.classList.add('opened');
  }

  function buildCatalyticPanel(root, points) {
    root.hidden = false;
    root.innerHTML = `
      <div class="cat-part" id="cat-part">
        <img class="cat-photo cat-photo-body" alt="" src="${CAT_BASE}catalytic_body.png">
        <img class="cat-photo cat-photo-open" alt="" src="${CAT_BASE}catalytic_open.png">
        <div class="cat-part-head">
          <span class="serial-part-tag">PE&Ccedil;A APREENDIDA</span>
          <span class="serial-part-kind">CATALISADOR</span>
        </div>
        <div class="cat-stage" id="cat-stage"></div>
        <div class="serial-hint">Desparafuse a flange (segure o clique e gire) e abra na marreta</div>
      </div>
      <img class="cat-tool" alt="" src="${CAT_BASE}catalytic_wrench.png" data-mode="wrench" hidden>`;

    _catPartEl = root.querySelector('#cat-part');
    const stage = root.querySelector('#cat-stage');
    const bodyImg = root.querySelector('.cat-photo-body');
    _catTool = root.querySelector('.cat-tool');
    bodyImg.addEventListener('load', () => _catPartEl.classList.add('cat-photo-ok'));
    bodyImg.addEventListener('error', () => _catPartEl.classList.remove('cat-photo-ok'));
    _catTool.addEventListener('load', () => { _catTool.dataset.ok = '1'; });

    // [VISUAL-02] Posições % (left,top) sobre catalytic_body.png (o painel usa a
    // proporção exata da foto, então % do painel == % da imagem). Ajuste aqui.
    //   corpo do catalisador ~ x 13-55% / y 33-71% ; costura soldada ~ y 51%
    const boltPos  = [ [18, 41], [47, 41], [18, 63], [47, 63] ];  // 4 cantos da face do corpo
    const knockPos = [ [25, 51], [40, 51] ];                       // EM CIMA da costura (entre os parafusos)
    let bi = 0, ki = 0;

    points.forEach((pt) => {
      const ptId = pt.id;
      const el = document.createElement('div');
      el.style.position = 'absolute';

      if (pt.primitive === 'rotate') {
        const [lx, ly] = boltPos[bi++] || [50, 50];
        el.className = 'hotspot primitive-rotate visual-exhaust-bolt cat-node';
        el.style.left = lx + '%'; el.style.top = ly + '%';
        el.innerHTML = `<svg class="hotspot-svg" viewBox="0 0 64 64">
          <circle class="hotspot-bg-circle" cx="32" cy="32" r="26"/>
          <circle class="hotspot-progress-circle" cx="32" cy="32" r="26"/></svg>`;
        const entry = {
          id: ptId, primitive: 'rotate', element: el,
          progressCircle: el.querySelector('.hotspot-progress-circle'),
          neededDeg: pt.neededDeg || 720, visualType: 'exhaust_bolt',
          unlockAfter: (typeof pt.unlockAfter === 'number') ? pt.unlockAfter : null,
          lockUntilOthers: false, accumulatedDeg: 0, progress: 0, completed: false, visible: true,
        };
        pointsMap[ptId] = entry;
        buildExhaustBolt(el, entry);
        if (entry.unlockAfter && entry.unlockAfter > 0) el.classList.add('locked');
        el.addEventListener('mousedown', (e) => {
          if (e.button !== 0 || entry.completed) return;
          if (!isPointUnlocked(entry)) {
            el.classList.add('strike-miss');
            setTimeout(() => el.classList.remove('strike-miss'), 170);
            e.preventDefault(); return;
          }
          activeHotspotId = ptId;
          el.classList.add('active');
          if (!entry._focused) { entry._focused = true; postNui('minigamePointStart', { id: ptId }); }
          const r = el.getBoundingClientRect();
          prevMouseAngle = Math.atan2(e.clientY - (r.top + r.height / 2), e.clientX - (r.left + r.width / 2));
          e.preventDefault();
        });
      } else if (pt.primitive === 'strike') {
        const [lx, ly] = knockPos[ki++] || [50, 78];
        el.className = 'hotspot primitive-strike cat-node';
        el.style.left = lx + '%'; el.style.top = ly + '%';
        el.innerHTML = `<svg class="hotspot-svg" viewBox="0 0 64 64">
          <circle class="hotspot-bg-circle" cx="32" cy="32" r="26"/>
          <circle class="hotspot-progress-circle" cx="32" cy="32" r="26"/>
          <circle class="strike-closer" cx="32" cy="32" r="${STRIKE_R_MAX}"/></svg>
          <div class="hotspot-inner"><span class="hotspot-icon">&#128296;</span></div>`;
        const entry = {
          id: ptId, primitive: 'strike', element: el,
          progressCircle: el.querySelector('.hotspot-progress-circle'),
          closerCircle: el.querySelector('.strike-closer'),
          icon: el.querySelector('.hotspot-icon'),
          hitsNeeded: Math.max(1, pt.hitsNeeded || 4), hits: 0,
          unlockAfter: (typeof pt.unlockAfter === 'number') ? pt.unlockAfter : null,
          lockUntilOthers: false, progress: 0, completed: false, visible: true,
        };
        pointsMap[ptId] = entry;
        if (entry.unlockAfter && entry.unlockAfter > 0) el.classList.add('locked');
        el.addEventListener('mousedown', (e) => {
          if (e.button !== 0 || entry.completed) return;
          if (!isPointUnlocked(entry)) {
            el.classList.add('strike-miss');
            setTimeout(() => el.classList.remove('strike-miss'), 170);
            e.preventDefault(); return;
          }
          if (!entry._focused) { entry._focused = true; postNui('minigamePointStart', { id: ptId }); }
          strikeAttempt(entry);
          e.preventDefault();
        });
      }
      stage.appendChild(el);
    });

    _catPanelActive = true;
    catUpdateTool();
    stopStrikeLoop();
    if (points.some((p) => p.primitive === 'strike')) {
      strikeRaf = requestAnimationFrame(strikeLoop);
    }
  }

  function startMinigame(data) {
    activeMinigame = true;
    hudTitle.textContent = data.title || 'OPERAÇÃO FÍSICA';
    hudHelp.textContent = data.helpText || 'Mantenha o clique e trabalhe sobre cada ponto';
    uxSpeedMult = data.uxSpeed || 1.0;
    traceTolerancePx = (typeof data.traceTolerance === 'number' && data.traceTolerance > 0) ? data.traceTolerance : 55.0;
    pointsMap = {};
    hotspotContainer.innerHTML = '';
    activeHotspotId = null;
    stopCuttingLoop();

    const points = data.points || [];

    const surfacePanel = document.getElementById('surface-panel');
    if (surfacePanel) { surfacePanel.hidden = true; surfacePanel.innerHTML = ''; }

    // Modo painel (serial / catalytic). Um erro no builder NÃO pode brickar o
    // resto da NUI — cai no fluxo de hotspots genérico se lançar.
    const panelBuilder = data.panel === 'serial' ? buildSerialPanel
      : data.panel === 'catalytic' ? buildCatalyticPanel : null;
    if (panelBuilder && surfacePanel) {
      try {
        panelBuilder(surfacePanel, points);
        updateOverallProgress();
        app.classList.remove('hidden');
        return;
      } catch (err) {
        console.error('[vp_chopshop] panel builder failed, falling back:', err);
        surfacePanel.hidden = true;
        surfacePanel.innerHTML = '';
        pointsMap = {};
      }
    }

    points.forEach((pt, index) => {
      const ptId = pt.id || `point_${index}`;
      const primitive = pt.primitive || (data.toolClass === 'cut' ? 'cut' : 'rotate');
      const neededDeg = pt.neededDeg || 720.0;
      const holdTimeMs = pt.holdTimeMs || 2200.0;
      
      const el = document.createElement('div');
      el.className = `hotspot primitive-${primitive}`;
      el.id = `hs-${ptId}`;
      el.style.left = `${(pt.x || 0.5) * 100}%`;
      el.style.top = `${(pt.y || 0.5) * 100}%`;

      let iconLabel = `${index + 1}`;
      if (primitive === 'cut') {
        iconLabel = '&#9986;';
      } else if (primitive === 'drill') {
        iconLabel = '&#9881;';
      } else if (primitive === 'trace' || primitive === 'strike') {
        iconLabel = '&#9874;'; // Hammer / pick / torch
      } else if (primitive === 'sand') {
        iconLabel = '&#8644;'; // vai-e-vem (lixar)
      }

      if (primitive === 'trace' && pt.path && pt.path.length >= 2) {
        el.className = 'hotspot primitive-trace';
        el.style.left = '0px';
        el.style.top = '0px';
        el.style.width = '100vw';
        el.style.height = '100vh';
        el.style.transform = 'none';
        el.style.pointerEvents = 'none';

        el.innerHTML = `
          <svg class="trace-svg" style="position:absolute;width:100%;height:100%;top:0;left:0;pointer-events:none;overflow:visible;">
            <path class="trace-bg-path" d="" />
            <path class="trace-fg-path" d="" />
          </svg>
          <div class="trace-node start-node">
            <span class="trace-icon">${index + 1}</span>
            <span class="trace-label">${pt.label || 'LINHA DE CORTE'}</span>
          </div>
          <div class="trace-torch-tip hidden"></div>
        `;

        const startNode = el.querySelector('.trace-node');
        const bgPath = el.querySelector('.trace-bg-path');
        const fgPath = el.querySelector('.trace-fg-path');
        const torchTip = el.querySelector('.trace-torch-tip');

        function updateSvgPath(pathNodes) {
          if (!pathNodes || pathNodes.length < 2) return;
          const w = window.innerWidth;
          const h = window.innerHeight;
          let d = '';
          let allNodesVisible = true;
          pathNodes.forEach((node, i) => {
            if (node.visible === false) {
              allNodesVisible = false;
            }
            const px = (node.x || 0.5) * w;
            const py = (node.y || 0.5) * h;
            d += (i === 0 ? `M ${px} ${py} ` : `L ${px} ${py} `);
            if (i === 0 && startNode) {
              if (node.visible !== false) {
                startNode.style.display = 'flex';
                startNode.style.left = `${px}px`;
                startNode.style.top = `${py}px`;
              } else {
                startNode.style.display = 'none';
              }
            }
          });
          if (pointsMap[ptId] && pointsMap[ptId].completed) {
            bgPath.style.display = 'none';
            fgPath.style.display = 'none';
            if (startNode) startNode.style.display = 'none';
            return;
          }

          if (!allNodesVisible) {
            bgPath.style.display = 'none';
            fgPath.style.display = 'none';
            return;
          }

          const isThisPointActive = (activeHotspotId === ptId);
          const hasActiveHotspot = (activeHotspotId !== null);

          if (hasActiveHotspot && !isThisPointActive) {
            bgPath.style.display = 'none';
            fgPath.style.display = 'none';
          } else {
            bgPath.style.display = 'block';
            fgPath.style.display = 'block';
          }

          bgPath.setAttribute('d', d);
          fgPath.setAttribute('d', d);
          const totalLen = fgPath.getTotalLength ? fgPath.getTotalLength() : 500;
          fgPath.style.strokeDasharray = totalLen;
          const pct = (pointsMap[ptId] && pointsMap[ptId].progress) || 0;
          fgPath.style.strokeDashoffset = totalLen * (1 - pct / 100);
        }

        updateSvgPath(pt.path);

        const w = window.innerWidth;
        const h = window.innerHeight;
        const initialP0 = { x: (pt.path[0].x || 0.5) * w, y: (pt.path[0].y || 0.5) * h };

        startNode.addEventListener('mousedown', (e) => {
          if (e.button !== 0) return;
          const currentPt = pointsMap[ptId];
          if (!currentPt || currentPt.completed) return;

          activeHotspotId = ptId;
          currentPt.isTracing = true;
          currentPt.lastPointerTimestamp = Date.now();
          el.classList.add('active', 'tracing');
          postNui('minigamePointStart', { id: ptId });
          if (torchTip) {
            const targetPos = currentPt.lastCutScreenPos || initialP0;
            torchTip.style.left = `${targetPos.x}px`;
            torchTip.style.top = `${targetPos.y}px`;
            torchTip.classList.remove('hidden');
          }
          e.preventDefault();
          e.stopPropagation();
        });

        hotspotContainer.appendChild(el);

        pointsMap[ptId] = {
          id: ptId,
          primitive: 'trace',
          element: el,
          bgPath: bgPath,
          fgPath: fgPath,
          startNode: startNode,
          torchTip: torchTip,
          path: pt.path,
          updateSvgPath: updateSvgPath,
          currentSegmentIndex: 0,
          currentSegmentT: 0,
          lastAcceptedT: 0,
          lastCutScreenPos: initialP0,
          lastPointerTimestamp: Date.now(),
          isTracing: false,
          progress: 0,
          completed: false,
          visible: true
        };
      } else {
        const closerCircleSvg = primitive === 'strike'
          ? `<circle class="strike-closer" cx="32" cy="32" r="${STRIKE_R_MAX}" />`
          : '';
        const defaultLabel = primitive === 'cut' ? 'CORTE'
          : primitive === 'drill' ? 'CALÇO'
          : primitive === 'strike' ? 'GOLPE' : 'PARAFUSO';
        el.innerHTML = `
          <svg class="hotspot-svg" viewBox="0 0 64 64">
            <circle class="hotspot-bg-circle" cx="32" cy="32" r="${CIRCLE_RADIUS}" />
            <circle class="hotspot-progress-circle" cx="32" cy="32" r="${CIRCLE_RADIUS}" />
            ${closerCircleSvg}
          </svg>
          <div class="hotspot-inner">
            <span class="hotspot-icon">${iconLabel}</span>
            <span class="hotspot-label">${pt.label || defaultLabel}</span>
          </div>
        `;

        el.addEventListener('mousedown', (e) => {
          if (e.button !== 0) return; // Only Left Click
          const thisPt = pointsMap[ptId];
          if (thisPt && thisPt.completed) return;
          if (thisPt && !isPointUnlocked(thisPt)) {
            el.classList.add('strike-miss');
            setTimeout(() => el && el.classList.remove('strike-miss'), 170);
            e.preventDefault();
            return;
          }

          if (primitive === 'strike') {
            if (thisPt && !thisPt._focused) {
              thisPt._focused = true;
              postNui('minigamePointStart', { id: ptId });
            }
            strikeAttempt(thisPt);
            e.preventDefault();
            return;
          }

          activeHotspotId = ptId;
          el.classList.add('active');
          postNui('minigamePointStart', { id: ptId });
          const rect = el.getBoundingClientRect();
          const centerX = rect.left + rect.width / 2;
          const centerY = rect.top + rect.height / 2;
          prevMouseAngle = Math.atan2(e.clientY - centerY, e.clientX - centerX);

          if (primitive === 'cut' || primitive === 'hold') {
            el.classList.add('cutting');
            startCuttingLoop(ptId);
          } else if (primitive === 'drill') {
            el.classList.add('drilling');
            startCuttingLoop(ptId);
          } else if (primitive === 'sand') {
            el.classList.add('sanding');
            thisPt._sandLastX = e.clientX;
            thisPt._sandDir = 0;
          }

          e.preventDefault();
        });

        hotspotContainer.appendChild(el);

        pointsMap[ptId] = {
          id: ptId,
          primitive: primitive,
          element: el,
          progressCircle: el.querySelector('.hotspot-progress-circle'),
          closerCircle: el.querySelector('.strike-closer'),
          icon: el.querySelector('.hotspot-icon'),
          neededDeg: neededDeg,
          holdTimeMs: holdTimeMs,
          hitsNeeded: Math.max(1, pt.hitsNeeded || 4),
          strokesNeeded: Math.max(3, pt.strokesNeeded || 8),
          strokes: 0,
          _sandDir: 0,
          _sandLastX: 0,
          hits: 0,
          accumulatedDeg: 0,
          progress: 0,
          completed: false,
          visible: true,
          lockUntilOthers: pt.lockUntilOthers === true,
          unlockAfter: (typeof pt.unlockAfter === 'number') ? pt.unlockAfter : null,
          visualType: pt.visualType || null
        };
        if (pt.lockUntilOthers === true || (typeof pt.unlockAfter === 'number' && pt.unlockAfter > 0)) {
          el.classList.add('locked');
        }
        // [VISUAL-01] overlay fotorrealista de fixação (renderer comum)
        if (pt.visualType === 'exhaust_bolt' && primitive === 'rotate') {
          el.classList.add('visual-exhaust-bolt');
          buildExhaustBolt(el, pointsMap[ptId]);
        }
      }
    });

    updateOverallProgress();
    app.classList.remove('hidden');

    stopStrikeLoop();
    if (points.some(p => (p.primitive === 'strike'))) {
      strikeRaf = requestAnimationFrame(strikeLoop);
    }
  }

  function updatePointsPosition(data) {
    if (!activeMinigame) return;
    const pts = data.points || [];
    pts.forEach(pt => {
      const entry = pointsMap[pt.id];
      if (entry && entry.element) {
        if (pt.visible === false) {
          entry.element.style.display = 'none';
        } else {
          entry.element.style.display = 'flex';
          if (entry.primitive === 'trace' && entry.updateSvgPath) {
            entry.path = pt.path;
            entry.updateSvgPath(pt.path);
          } else {
            entry.element.style.left = `${pt.x * 100}%`;
            entry.element.style.top = `${pt.y * 100}%`;
          }
        }
      }
    });
  }

  function stopMinigame() {
    activeMinigame = false;
    activeHotspotId = null;
    stopCuttingLoop();
    stopStrikeLoop();
    app.classList.add('hidden');
    hotspotContainer.innerHTML = '';
    const sp = document.getElementById('surface-panel');
    if (sp) { sp.hidden = true; sp.innerHTML = ''; }
    _serialPanelActive = false;
    _serialSanding = false;
    _serialCells = [];
    _serialPoints = {};
    _serialSander = null;
    _catPanelActive = false;
    _catTool = null;
    _catPartEl = null;
    pointsMap = {};
  }

  function updateOverallProgress() {
    const keys = Object.keys(pointsMap);
    if (keys.length === 0) return;
    let totalProgress = 0;
    let completedCount = 0;
    keys.forEach(k => {
      totalProgress += pointsMap[k].progress;
      if (pointsMap[k].completed) completedCount++;
    });
    const avg = Math.floor(totalProgress / keys.length);
    overallProgressText.textContent = `${avg}% (${completedCount}/${keys.length})`;
    overallProgressFill.style.width = `${avg}%`;
    refreshLockedPoints();

    if (completedCount === keys.length && keys.length > 0) {
      setTimeout(() => {
        postNui('minigameFinish', { success: true });
      }, 200);
    }
  }

  // ─── Mouse Motion & Gesture Tracking (Rotate & Trace Primitives) ────────────
  window.addEventListener('mousedown', (e) => {
    if (e.button !== 0 || !activeMinigame || activeHotspotId) return;
    const w = window.innerWidth;
    const h = window.innerHeight;
    for (const k in pointsMap) {
      const pt = pointsMap[k];
      if (pt && pt.primitive === 'trace' && !pt.completed) {
        const initialP0 = { x: (pt.path[0].x || 0.5) * w, y: (pt.path[0].y || 0.5) * h };
        const targetPos = pt.lastCutScreenPos || initialP0;
        const dist = Math.hypot(e.clientX - targetPos.x, e.clientY - targetPos.y);
        if (dist <= traceTolerancePx) {
          activeHotspotId = k;
          pt.isTracing = true;
          pt.lastPointerTimestamp = Date.now();
          pt.element.classList.add('active', 'tracing');
          postNui('minigamePointStart', { id: k });
          if (pt.torchTip) {
            pt.torchTip.style.left = `${targetPos.x}px`;
            pt.torchTip.style.top = `${targetPos.y}px`;
            pt.torchTip.classList.remove('hidden');
          }
          e.preventDefault();
          break;
        }
      }
    }
  });

  window.addEventListener('mousemove', (e) => {
    if (!activeMinigame || !activeHotspotId) return;
    const pt = pointsMap[activeHotspotId];
    if (!pt || pt.completed) return;

    if (pt.primitive === 'rotate') {
      const rect = pt.element.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;

      const currentAngle = Math.atan2(e.clientY - centerY, e.clientX - centerX);
      let delta = currentAngle - prevMouseAngle;

      if (delta > Math.PI) delta -= 2 * Math.PI;
      if (delta < -Math.PI) delta += 2 * Math.PI;

      const deltaDeg = Math.abs(delta) * (180 / Math.PI);
      if (deltaDeg > 0 && deltaDeg < 60) {
        pt.accumulatedDeg += deltaDeg * uxSpeedMult;
        pt.progress = Math.min(100, Math.floor((pt.accumulatedDeg / pt.neededDeg) * 100));

        if (pt.progressCircle) {
          pt.progressCircle.style.strokeDashoffset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
        }
        if (pt.visualType === 'exhaust_bolt') updateExhaustBoltVisual(pt);

        if (pt.progress >= 100) {
          completePoint(pt);
        } else {
          updateOverallProgress();
        }
      }
      prevMouseAngle = currentAngle;
    } else if (pt.primitive === 'sand') {
      // [FIX-1.3] Lixar: esfregar o mouse pra frente e pra trás sobre o número.
      // Cada inversão de direção com deslocamento mínimo conta 1 passada.
      showSander(e.clientX, e.clientY);  // [VISUAL-01B] a lixa segue o cursor
      const dx = e.clientX - (pt._sandLastX || e.clientX);
      if (Math.abs(dx) >= 6) {
        const dir = dx > 0 ? 1 : -1;
        if (pt._sandDir !== 0 && dir !== pt._sandDir) {
          pt.strokes = (pt.strokes || 0) + 1;
          pt.progress = Math.min(100, Math.floor((pt.strokes / pt.strokesNeeded) * 100));
          if (pt.progressCircle) {
            pt.progressCircle.style.strokeDashoffset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
          }
          if (typeof pt.onProgress === 'function') pt.onProgress(pt.progress);
          pt.element.classList.remove('sand-tick');
          void pt.element.offsetWidth;
          pt.element.classList.add('sand-tick');
          if (pt.progress >= 100) {
            completePoint(pt);
          } else {
            updateOverallProgress();
          }
        }
        pt._sandDir = dir;
        pt._sandLastX = e.clientX;
      }
    } else if (pt.primitive === 'trace' && pt.isTracing && pt.path && pt.path.length >= 2) {
      // ─── Structural Trace: Anti-Cheese & Intra-Segment Hardening ─────────
      const now = Date.now();
      const dt = Math.min(0.1, Math.max(0.001, (now - (pt.lastPointerTimestamp || now)) / 1000.0));
      pt.lastPointerTimestamp = now;

      const w = window.innerWidth;
      const h = window.innerHeight;
      const segIdx = pt.currentSegmentIndex || 0;
      const totalSegs = pt.path.length - 1;

      if (segIdx < totalSegs) {
        const p0 = { x: (pt.path[segIdx].x || 0.5) * w, y: (pt.path[segIdx].y || 0.5) * h };
        const p1 = { x: (pt.path[segIdx + 1].x || 0.5) * w, y: (pt.path[segIdx + 1].y || 0.5) * h };

        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const segLenPx = Math.hypot(dx, dy);

        if (segLenPx > 1) {
          // Orthogonal projection of cursor onto active segment
          const u = ((e.clientX - p0.x) * dx + (e.clientY - p0.y) * dy) / (segLenPx * segLenPx);
          const tClamped = Math.max(0, Math.min(1, u));

          const projX = p0.x + tClamped * dx;
          const projY = p0.y + tClamped * dy;
          const distToSeg = Math.hypot(e.clientX - projX, e.clientY - projY);

          const tolerancePx = traceTolerancePx;
          if (distToSeg <= tolerancePx) {
            // Speed limit anti-cheese: cap max advance per frame based on time and trace speed
            const maxSpeedPxS = 400 * (uxSpeedMult || 1.0);
            const maxAdvancePx = maxSpeedPxS * dt + 30; // frame tolerance
            const maxAdvanceT = maxAdvancePx / Math.max(1, segLenPx);

            // 1. Anti-Jump / Teleport rejection
            if (tClamped > (pt.currentSegmentT || 0) + maxAdvanceT) {
              return; // Teleport jump rejected!
            }

            // 2. Backward motion: update visual spark tip position but do not increase progress
            if (tClamped < (pt.currentSegmentT || 0)) {
              if (pt.torchTip) {
                pt.torchTip.style.left = `${projX}px`;
                pt.torchTip.style.top = `${projY}px`;
              }
              return;
            }

            // 3. Legitimate forward movement
            pt.currentSegmentT = tClamped;
            pt.lastAcceptedT = tClamped;
            pt.lastCutScreenPos = { x: projX, y: projY };

            if (pt.torchTip) {
              pt.torchTip.style.left = `${projX}px`;
              pt.torchTip.style.top = `${projY}px`;
            }

            // Segment transition: must reach >= 0.98 and be physically near next vertex
            const distToEnd = Math.hypot(e.clientX - p1.x, e.clientY - p1.y);
            if (tClamped >= 0.98 && distToEnd <= 45) {
              if (segIdx + 1 < totalSegs) {
                pt.currentSegmentIndex = segIdx + 1;
                pt.currentSegmentT = 0.0;
                pt.lastAcceptedT = 0.0;
              } else {
                pt.progress = 100;
                completePoint(pt);
                return;
              }
            }

            // Overall trace progress computation
            const totalProgressRatio = (pt.currentSegmentIndex + (pt.currentSegmentT || 0)) / totalSegs;
            pt.progress = Math.min(100, Math.floor(totalProgressRatio * 100));

            if (pt.fgPath) {
              const totalLen = pt.fgPath.getTotalLength ? pt.fgPath.getTotalLength() : 500;
              pt.fgPath.style.strokeDashoffset = totalLen * (1 - pt.progress / 100);
            }

            updateOverallProgress();
          }
        }
      }
    }
  });

  window.addEventListener('mouseup', () => {
    if (activeHotspotId && pointsMap[activeHotspotId]) {
      const pt = pointsMap[activeHotspotId];
      pt.isTracing = false;
      pt.element.classList.remove('active', 'cutting', 'drilling', 'tracing', 'sanding');
      if (pt.torchTip) pt.torchTip.classList.add('hidden');
    }
    _serialSanding = false;
    if (!_serialPanelActive) hideSander();
    stopCuttingLoop();
    activeHotspotId = null;
  });

  // [VISUAL-01C] Lixamento livre no painel de série: a lixa segue o cursor;
  // segurando LMB e passando sobre o número, desgasta as células.
  document.addEventListener('mousemove', (e) => {
    if (_serialPanelActive) {
      showSander(e.clientX, e.clientY);
      serialSandAt(e.clientX, e.clientY);
    }
    if (_catPanelActive && _catTool && _catTool.dataset.ok === '1') {
      _catTool.hidden = false;
      _catTool.style.left = e.clientX + 'px';
      _catTool.style.top = e.clientY + 'px';
    }
  });
  document.addEventListener('mousedown', (e) => {
    if (!_serialPanelActive || e.button !== 0) return;
    _serialSanding = true;
    serialSandAt(e.clientX, e.clientY);
  });

  // ─── Escape / Cancel Key Listener ──────────────────────────────────────────
  window.addEventListener('keydown', (e) => {
    if (!activeMinigame) return;
    if (e.key === 'Escape' || e.keyCode === 27 || e.key === 'Backspace' || e.keyCode === 8) {
      postNui('minigameCancel', { reason: 'user_cancel' });
    }
  });

  // ─── FiveM Message Dispatcher ──────────────────────────────────────────────
  window.addEventListener('message', (event) => {
    const item = event.data;
    if (!item || !item.action) return;

    switch (item.action) {
      case 'minigame:start':
        startMinigame(item.data || {});
        break;
      case 'minigame:updatePoints':
        updatePointsPosition(item.data || {});
        break;
      case 'minigame:stop':
        stopMinigame();
        break;
    }
  });
})();
