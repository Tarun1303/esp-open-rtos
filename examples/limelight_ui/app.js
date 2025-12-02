const flexChips = [
  { label: 'Chiller +0.8°C ≈ 38 kW' },
  { label: 'AHUs +0.5°C ≈ 27 kW' },
  { label: 'VFD −8% ≈ 17 kW' },
  { label: 'Lighting −15% ≈ 10 kW' },
];

const cohortRows = [
  ['CHILLER-PLANT-01', 38, 'Low', 'High', '—'],
  ['AHU-BAY-1', 12, 'Low', 'Medium', '—'],
  ['FAN-VFD-GROUP', 17, 'Low', 'High', '—'],
  ['LIGHTING-PLANT', 10, 'Low', 'High', '—'],
];

const healthStats = [
  'AMI Latency: 0m',
  'EMS Link: OK',
  'Write Success (24h): 99.1%',
  'Rollbacks: 0',
  'Comfort Violations: 0',
];

const timelineEntries = [
  '17:45 Staged plan EVT-2025-12-01-1800 (Tarun)',
  '17:40 Model refresh: Forecast P50/P90',
  '16:10 Policy updated: Lighting trim cap −25%',
];

const rankCandidates = [
  { id: 'CHILLER-PLANT-01', control: 'CHW +0.8°C', flex: 38, comfort: 'Low', confidence: 'High', notes: 'COP nominal' },
  { id: 'AHU-BAY-1', control: 'SAT +0.5°C', flex: 9, comfort: 'Low', confidence: 'Medium', notes: 'Bay 1 occupancy high' },
  { id: 'FAN-VFD-GROUP', control: 'Cap −8%', flex: 17, comfort: 'Low', confidence: 'High', notes: 'SP margin OK' },
  { id: 'LIGHTING-PLANT', control: 'Trim −15%', flex: 10, comfort: 'Low', confidence: 'High', notes: 'Exclude QC aisles' },
];

const dispatchControls = [
  { id: 'CHILLER-PLANT-01', label: 'Chilled Water Set-Point Δ', range: '0.0 → +1.0°C', current: '+0.8°C', flex: 38, comfort: 'Low', badge: 'Writable' },
  { id: 'AHU-BAY-1', label: 'Supply Air Δ', range: '0.0 → +1.0°C', current: '+0.5°C', flex: 9, comfort: 'Low', badge: 'Writable' },
  { id: 'FAN-VFD-GROUP', label: 'Cap', range: '0 → −12%', current: '−8%', flex: 17, comfort: 'Low', badge: 'Writable' },
  { id: 'LIGHTING-PLANT', label: 'Trim', range: '0 → −25%', current: '−15%', flex: 10, comfort: 'Low', badge: 'Writable (QC aisles excluded)' },
];

const ledgerRows = [
  ['18:00', '1.90', '1.78', '0.12', '0.03', '0.08', '0.15'],
  ['18:15', '1.95', '1.80', '0.15', '0.04', '0.10', '0.18'],
  ['18:30', '1.92', '1.79', '0.13', '0.03', '0.09', '0.16'],
  ['18:45', '1.90', '1.79', '0.11', '0.03', '0.08', '0.15'],
];

const assetRows = [
  ['CHILLER-PLANT-01', 'Utilities', 230, 'Yes', '—', '—'],
  ['CR-4H-01', 'Process', 320, 'No', '—', 'High load'],
  ['LIGHTING-PLANT', 'Lighting', 80, 'Yes', '—', 'QC aisles excluded'],
];

const amiSamples = [
  ['2025-12-01 15:00', '1.70', '0.43', '29.1', 'Peak', 'Mon'],
  ['2025-12-01 15:15', '1.74', '0.44', '29.4', 'Peak', 'Mon'],
  ['2025-12-01 15:30', '1.91', '0.48', '29.7', 'Peak', 'Mon'],
  ['2025-12-01 15:45', '1.85', '0.46', '29.8', 'Peak', 'Mon'],
];

const emsSamples = [
  ['2025-12-01 15:35', 'CHILLER-PLANT-01', 'CHW_SP', '6.5', '°C'],
  ['2025-12-01 15:35', 'FAN-VFD-GROUP', 'CAP', '92', '%'],
];

const auditEvents = [
  ['17:45', 'Tarun', 'Stage plan', 'EVT-2025-12-01-1800', '4 actions', 'OK'],
  ['16:10', 'Tarun', 'Update policy', 'Lighting trim cap → −25%', '—', 'OK'],
];

const accessRows = [
  ['Tarun', 'Admin', 'On', '2025-12-01 09:10', 'All sites'],
  ['Riya', 'Operator', 'On', '2025-12-01 08:40', 'Marudhar'],
  ['Sachin', 'Analyst', 'Off', '2025-12-01 07:20', 'Marudhar'],
];

function renderList(targetId, items) {
  const target = document.getElementById(targetId);
  target.innerHTML = items.map((item) => `<li>${item}</li>`).join('');
}

function renderTable(targetId, rows) {
  const target = document.getElementById(targetId);
  target.innerHTML = rows.map((row) => `<tr>${row.map((cell) => `<td>${cell}</td>`).join('')}</tr>`).join('');
}

function renderFlexChips() {
  const target = document.getElementById('flexChips');
  target.innerHTML = flexChips.map((chip) => `<span class="chip chip--solid">${chip.label}</span>`).join('');
}

function renderRankTable() {
  const table = document.getElementById('rankTable');
  table.innerHTML = rankCandidates
    .map((candidate) => `
      <tr>
        <td><input type="checkbox" data-id="${candidate.id}" data-flex="${candidate.flex}" class="rank-check"></td>
        <td>${candidate.id}</td>
        <td>${candidate.control}</td>
        <td>${candidate.flex} kW</td>
        <td>${candidate.comfort}</td>
        <td>${candidate.confidence}</td>
        <td>${candidate.notes}</td>
      </tr>
    `)
    .join('');
}

function renderDispatchControls() {
  const grid = document.getElementById('dispatchControls');
  grid.innerHTML = dispatchControls
    .map((item) => `
      <div class="control-tile">
        <div class="card__header"><strong>${item.id}</strong><span class="badge">${item.badge}</span></div>
        <p>${item.label} (${item.range})</p>
        <input type="range" min="0" max="100" value="50" class="slider">
        <div class="chip-row"><span class="chip chip--solid">Est −${item.flex} kW</span><span class="chip chip--solid">Comfort: ${item.comfort}</span></div>
        <p class="microcopy">Current ${item.current}</p>
      </div>
    `)
    .join('');
}

function renderLiveLog(message) {
  const log = document.getElementById('liveLog');
  const node = document.createElement('li');
  node.textContent = message;
  log.prepend(node);
}

function showToast(message) {
  const toast = document.getElementById('toast');
  toast.textContent = message;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 2400);
}

function handleNav() {
  document.querySelectorAll('.nav__item').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.nav__item').forEach((b) => b.classList.remove('active'));
      btn.classList.add('active');
      const target = btn.dataset.target;
      document.querySelectorAll('.page').forEach((page) => page.classList.remove('active'));
      document.getElementById(target).classList.add('active');
    });
  });
}

function handlePackers() {
  const table = document.getElementById('rankTable');
  const meterFill = document.getElementById('meterFill');
  const meterValue = document.getElementById('meterValue');
  const meterTarget = document.getElementById('meterTarget');
  const chipList = document.getElementById('selectedList');
  const targetSlider = document.getElementById('targetSlider');
  const targetValue = document.getElementById('targetValue');

  targetSlider.addEventListener('input', (e) => {
    targetValue.textContent = e.target.value;
    meterTarget.textContent = e.target.value;
    updateMeter();
  });

  table.addEventListener('change', (e) => {
    if (e.target.classList.contains('rank-check')) {
      updateMeter();
    }
  });

  function updateMeter() {
    const selected = Array.from(document.querySelectorAll('.rank-check:checked'));
    const total = selected.reduce((sum, el) => sum + Number(el.dataset.flex), 0);
    meterValue.textContent = total;
    const target = Number(targetSlider.value);
    const pct = Math.min(100, Math.round((total / target) * 100));
    meterFill.style.width = `${pct}%`;
    chipList.innerHTML = selected.map((el) => `<span class="chip chip--solid">${el.dataset.id} (${el.dataset.flex} kW)</span>`).join('') || 'No selection';
  }

  updateMeter();
}

function handleScenario() {
  const targetReduction = document.getElementById('targetReduction');
  const eventLength = document.getElementById('eventLength');
  const feasibleFlex = document.getElementById('feasibleFlex');

  function recalc() {
    const reduction = Number(targetReduction.value);
    const length = Number(eventLength.value);
    const estimate = Math.round(reduction * 18 + (length - 30) * 0.8 + 60);
    feasibleFlex.textContent = estimate;
  }

  targetReduction.addEventListener('input', recalc);
  eventLength.addEventListener('input', recalc);
  recalc();
}

function handleDispatchActions() {
  const stageBtn = document.getElementById('stageBtn');
  const commitBtn = document.getElementById('commitBtn');
  const rollbackBtn = document.getElementById('rollbackBtn');
  const dispatchStatus = document.getElementById('dispatchStatus');

  stageBtn.addEventListener('click', () => {
    dispatchStatus.textContent = 'Staged';
    dispatchStatus.parentElement.querySelector('.pill').className = 'pill pill--staged';
    commitBtn.disabled = false;
    rollbackBtn.disabled = false;
    renderLiveLog('Plan staged — writes simulated; comfort OK.');
    showToast('Plan staged.');
  });

  commitBtn.addEventListener('click', () => {
    if (commitBtn.disabled) return;
    dispatchStatus.textContent = 'Committed';
    dispatchStatus.parentElement.querySelector('.pill').className = 'pill pill--committed';
    renderLiveLog('Dispatch committed — control writes sent.');
    showToast('Dispatch committed.');
  });

  rollbackBtn.addEventListener('click', () => {
    dispatchStatus.textContent = 'Rolled back';
    dispatchStatus.parentElement.querySelector('.pill').className = 'pill pill--rolled';
    renderLiveLog('Rollback completed — points restored.');
    showToast('Rollback completed.');
  });
}

function handleShortcuts() {
  const mapping = {
    'g+o': 'overview',
    'g+f': 'forecast',
    'g+x': 'flex',
    'g+d': 'dispatch',
    'g+m': 'mv',
  };

  document.addEventListener('keydown', (e) => {
    const key = `${e.key.toLowerCase()}`;
    if (e.key.toLowerCase() === 'g') {
      document._go = true;
    } else if (document._go && mapping[`g+${key}`]) {
      const target = mapping[`g+${key}`];
      document.querySelector(`.nav__item[data-target="${target}"]`).click();
      document._go = false;
    }

    if (document.getElementById('dispatch').classList.contains('active')) {
      if (e.key.toLowerCase() === 's') document.getElementById('stageBtn').click();
      if (e.key.toLowerCase() === 'c') document.getElementById('commitBtn').click();
      if (e.key.toLowerCase() === 'r') document.getElementById('rollbackBtn').click();
    }
  });
}

function init() {
  renderFlexChips();
  renderTable('cohortTable', cohortRows);
  renderList('healthStats', healthStats);
  renderList('timeline', timelineEntries);
  renderRankTable();
  renderDispatchControls();
  renderTable('ledgerTable', ledgerRows);
  renderTable('assetTable', assetRows);
  renderTable('amiTable', amiSamples);
  renderTable('emsTable', emsSamples);
  renderTable('auditTable', auditEvents);
  renderTable('accessTable', accessRows);

  renderLiveLog('18:00:05 Commit accepted');
  renderLiveLog('18:00:07 Write CHW_SP +0.8°C → OK');
  renderLiveLog('18:00:09 Write AHU SAT +0.5°C → OK');
  renderLiveLog('18:00:12 Write VFD cap −8% → OK');
  renderLiveLog('18:00:15 Lighting trim −15% → OK');

  handleNav();
  handlePackers();
  handleScenario();
  handleDispatchActions();
  handleShortcuts();
}

document.addEventListener('DOMContentLoaded', init);
