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

  let activeMinigame = false;
  let pointsMap = {};
  let activeHotspotId = null;
  let prevMouseAngle = 0;
  let uxSpeedMult = 1.0;
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
    pt.progressCircle.style.strokeDashoffset = 0;
    pt.element.classList.remove('active', 'cutting', 'drilling');
    pt.element.classList.add('completed');
    pt.icon.innerHTML = '&#10003;'; // Checkmark
    postNui('minigamePointComplete', { id: pt.id });
    activeHotspotId = null;
    stopCuttingLoop();
    updateOverallProgress();
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

  function startMinigame(data) {
    activeMinigame = true;
    hudTitle.textContent = data.title || 'OPERAÇÃO FÍSICA';
    hudHelp.textContent = data.helpText || 'Mantenha o clique e trabalhe sobre cada ponto';
    uxSpeedMult = data.uxSpeed || 1.0;
    pointsMap = {};
    hotspotContainer.innerHTML = '';
    activeHotspotId = null;
    stopCuttingLoop();

    const points = data.points || [];
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
      }

      el.innerHTML = `
        <svg class="hotspot-svg" viewBox="0 0 64 64">
          <circle class="hotspot-bg-circle" cx="32" cy="32" r="${CIRCLE_RADIUS}" />
          <circle class="hotspot-progress-circle" cx="32" cy="32" r="${CIRCLE_RADIUS}" />
        </svg>
        <div class="hotspot-inner">
          <span class="hotspot-icon">${iconLabel}</span>
          <span class="hotspot-label">${pt.label || (primitive === 'cut' ? 'CORTE' : (primitive === 'drill' ? 'CALÇO' : 'PARAFUSO'))}</span>
        </div>
      `;

      el.addEventListener('mousedown', (e) => {
        if (e.button !== 0) return; // Only Left Click
        if (pointsMap[ptId] && pointsMap[ptId].completed) return;
        
        activeHotspotId = ptId;
        el.classList.add('active');
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
        }

        e.preventDefault();
      });

      hotspotContainer.appendChild(el);

      pointsMap[ptId] = {
        id: ptId,
        primitive: primitive,
        element: el,
        progressCircle: el.querySelector('.hotspot-progress-circle'),
        icon: el.querySelector('.hotspot-icon'),
        neededDeg: neededDeg,
        holdTimeMs: holdTimeMs,
        accumulatedDeg: 0,
        progress: 0,
        completed: false,
        visible: true
      };
    });

    updateOverallProgress();
    app.classList.remove('hidden');
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
          entry.element.style.left = `${pt.x * 100}%`;
          entry.element.style.top = `${pt.y * 100}%`;
        }
      }
    });
  }

  function stopMinigame() {
    activeMinigame = false;
    activeHotspotId = null;
    stopCuttingLoop();
    app.classList.add('hidden');
    hotspotContainer.innerHTML = '';
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

    if (completedCount === keys.length && keys.length > 0) {
      setTimeout(() => {
        postNui('minigameFinish', { success: true });
      }, 200);
    }
  }

  // ─── Mouse Motion & Gesture Tracking (Rotate Primitive) ─────────────────────
  window.addEventListener('mousemove', (e) => {
    if (!activeMinigame || !activeHotspotId) return;
    const pt = pointsMap[activeHotspotId];
    if (!pt || pt.completed) return;

    if (pt.primitive !== 'rotate') return;

    const rect = pt.element.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;

    const currentAngle = Math.atan2(e.clientY - centerY, e.clientX - centerX);
    let delta = currentAngle - prevMouseAngle;

    // Normalize delta across [-PI, PI] boundary
    if (delta > Math.PI) delta -= 2 * Math.PI;
    if (delta < -Math.PI) delta += 2 * Math.PI;

    const deltaDeg = Math.abs(delta) * (180 / Math.PI);
    // Discard erratic mouse jumps
    if (deltaDeg > 0 && deltaDeg < 60) {
      pt.accumulatedDeg += deltaDeg * uxSpeedMult;
      pt.progress = Math.min(100, Math.floor((pt.accumulatedDeg / pt.neededDeg) * 100));

      const offset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
      pt.progressCircle.style.strokeDashoffset = offset;

      if (pt.progress >= 100) {
        completePoint(pt);
      } else {
        updateOverallProgress();
      }
    }

    prevMouseAngle = currentAngle;
  });

  window.addEventListener('mouseup', () => {
    if (activeHotspotId && pointsMap[activeHotspotId]) {
      const pt = pointsMap[activeHotspotId];
      pt.element.classList.remove('active', 'cutting', 'drilling');
    }
    stopCuttingLoop();
    activeHotspotId = null;
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
