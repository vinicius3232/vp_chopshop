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
      } else if (primitive === 'trace') {
        iconLabel = '&#9874;'; // Hammer / pick / torch
      }

      if (primitive === 'trace' && pt.path && pt.path.length >= 2) {
        el.className = 'hotspot primitive-trace';
        el.style.left = '0px';
        el.style.top = '0px';
        el.style.width = '100vw';
        el.style.height = '100vh';
        el.style.transform = 'none';

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
          pathNodes.forEach((node, i) => {
            const px = (node.x || 0.5) * w;
            const py = (node.y || 0.5) * h;
            d += (i === 0 ? `M ${px} ${py} ` : `L ${px} ${py} `);
            if (i === 0 && startNode) {
              startNode.style.left = `${px}px`;
              startNode.style.top = `${py}px`;
            }
          });
          bgPath.setAttribute('d', d);
          fgPath.setAttribute('d', d);
          const totalLen = fgPath.getTotalLength ? fgPath.getTotalLength() : 500;
          fgPath.style.strokeDasharray = totalLen;
          const pct = (pointsMap[ptId] && pointsMap[ptId].progress) || 0;
          fgPath.style.strokeDashoffset = totalLen * (1 - pct / 100);
        }

        updateSvgPath(pt.path);

        startNode.addEventListener('mousedown', (e) => {
          if (e.button !== 0) return;
          if (pointsMap[ptId] && pointsMap[ptId].completed) return;
          activeHotspotId = ptId;
          el.classList.add('active', 'tracing');
          if (torchTip) torchTip.classList.remove('hidden');
          e.preventDefault();
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
          progress: 0,
          completed: false,
          visible: true
        };
      } else {
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
      }
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

  // ─── Mouse Motion & Gesture Tracking (Rotate & Trace Primitives) ────────────
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

        const offset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
        pt.progressCircle.style.strokeDashoffset = offset;

        if (pt.progress >= 100) {
          completePoint(pt);
        } else {
          updateOverallProgress();
        }
      }
      prevMouseAngle = currentAngle;
    } else if (pt.primitive === 'trace' && pt.path && pt.path.length >= 2) {
      // ─── Structural Trace / Polyline Cutter with Anti-Cheese ─────────────
      const w = window.innerWidth;
      const h = window.innerHeight;
      const segIdx = pt.currentSegmentIndex || 0;
      const totalSegs = pt.path.length - 1;

      if (segIdx < totalSegs) {
        const p0 = { x: (pt.path[segIdx].x || 0.5) * w, y: (pt.path[segIdx].y || 0.5) * h };
        const p1 = { x: (pt.path[segIdx + 1].x || 0.5) * w, y: (pt.path[segIdx + 1].y || 0.5) * h };

        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const segLenSq = dx * dx + dy * dy;

        if (segLenSq > 1) {
          // Orthogonal projection of cursor onto segment line
          const u = ((e.clientX - p0.x) * dx + (e.clientY - p0.y) * dy) / segLenSq;
          const tClamped = Math.max(0, Math.min(1, u));

          const projX = p0.x + tClamped * dx;
          const projY = p0.y + tClamped * dy;
          const distToSeg = Math.hypot(e.clientX - projX, e.clientY - projY);

          const tolerancePx = 60; // Safe tolerance margin
          if (distToSeg <= tolerancePx) {
            // Anti-cheese: forward motion only with smooth advance
            if (tClamped >= (pt.currentSegmentT || 0)) {
              pt.currentSegmentT = tClamped;

              // Move torch spark tip to projected cut location
              if (pt.torchTip) {
                pt.torchTip.style.left = `${projX}px`;
                pt.torchTip.style.top = `${projY}px`;
              }

              // Advance to next segment if reached the end of current segment
              if (tClamped >= 0.95) {
                if (segIdx + 1 < totalSegs) {
                  pt.currentSegmentIndex = segIdx + 1;
                  pt.currentSegmentT = 0;
                } else {
                  pt.progress = 100;
                  completePoint(pt);
                  return;
                }
              }

              // Overall trace progress
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
    }
  });

  window.addEventListener('mouseup', () => {
    if (activeHotspotId && pointsMap[activeHotspotId]) {
      const pt = pointsMap[activeHotspotId];
      pt.element.classList.remove('active', 'cutting', 'drilling', 'tracing');
      if (pt.torchTip) pt.torchTip.classList.add('hidden');
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
