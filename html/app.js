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
      if (pt.icon) {
        pt.icon.innerHTML = '&#10003;';
      }
    }

    if (pt.element && pt.primitive !== 'trace') {
      pt.element.classList.remove('active', 'cutting', 'drilling', 'tracing');
      pt.element.classList.add('completed');
    }

    postNui('minigamePointComplete', { id: pt.id });
    activeHotspotId = null;
    stopCuttingLoop();
    updateOverallProgress();

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

        const offset = CIRCLE_CIRCUMFERENCE * (1 - pt.progress / 100);
        pt.progressCircle.style.strokeDashoffset = offset;

        if (pt.progress >= 100) {
          completePoint(pt);
        } else {
          updateOverallProgress();
        }
      }
      prevMouseAngle = currentAngle;
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
