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

  function postNui(event, data = {}) {
    const resourceName = window.GetParentResourceName ? window.GetParentResourceName() : 'vp_chopshop';
    fetch(`https://${resourceName}/${event}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data)
    }).catch(() => {});
  }

  function startMinigame(data) {
    activeMinigame = true;
    hudTitle.textContent = data.title || 'OPERAÇÃO FÍSICA';
    hudHelp.textContent = data.helpText || 'Mantenha o clique e gire o mouse ao redor do fixador';
    uxSpeedMult = data.uxSpeed || 1.0;
    pointsMap = {};
    hotspotContainer.innerHTML = '';
    activeHotspotId = null;

    const points = data.points || [];
    points.forEach((pt, index) => {
      const ptId = pt.id || `point_${index}`;
      const neededDeg = (pt.neededDeg || 720.0) / uxSpeedMult;
      
      const el = document.createElement('div');
      el.className = 'hotspot';
      el.id = `hs-${ptId}`;
      el.style.left = `${(pt.x || 0.5) * 100}%`;
      el.style.top = `${(pt.y || 0.5) * 100}%`;

      el.innerHTML = `
        <svg class="hotspot-svg" viewBox="0 0 64 64">
          <circle class="hotspot-bg-circle" cx="32" cy="32" r="${CIRCLE_RADIUS}" />
          <circle class="hotspot-progress-circle" cx="32" cy="32" r="${CIRCLE_RADIUS}" />
        </svg>
        <div class="hotspot-inner">
          <span class="hotspot-icon">${index + 1}</span>
          <span class="hotspot-label">${pt.label || 'PARAFUSO'}</span>
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
        e.preventDefault();
      });

      hotspotContainer.appendChild(el);

      pointsMap[ptId] = {
        id: ptId,
        element: el,
        progressCircle: el.querySelector('.hotspot-progress-circle'),
        icon: el.querySelector('.hotspot-icon'),
        neededDeg: neededDeg,
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

  // ─── Mouse Motion & Gesture Tracking ────────────────────────────────────────
  window.addEventListener('mousemove', (e) => {
    if (!activeMinigame || !activeHotspotId) return;
    const pt = pointsMap[activeHotspotId];
    if (!pt || pt.completed) return;

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
      pt.accumulatedDeg += deltaDeg;
      pt.progress = Math.min(100, Math.floor((pt.accumulatedDeg / pt.neededDeg) * 100));

      const offset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
      pt.progressCircle.style.strokeDashoffset = offset;

      if (pt.progress >= 100 && !pt.completed) {
        pt.completed = true;
        pt.element.classList.remove('active');
        pt.element.classList.add('completed');
        pt.icon.innerHTML = '&#10003;'; // Checkmark
        postNui('minigamePointComplete', { id: pt.id });
        activeHotspotId = null;
      }

      updateOverallProgress();
    }

    prevMouseAngle = currentAngle;
  });

  window.addEventListener('mouseup', () => {
    if (activeHotspotId && pointsMap[activeHotspotId]) {
      pointsMap[activeHotspotId].element.classList.remove('active');
    }
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
