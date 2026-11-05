#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const os = require('os');

const REGISTRY = path.join(os.tmpdir(), 'claude-wt-pets-registry.json');
const OWNER_MAP = path.join(os.tmpdir(), 'claude-wt-pets-owner-map.json');
const LOCK_FILE = path.join(os.tmpdir(), 'claude-wt-pets-registry.lock');
const TRANSITION_LOG = path.join(os.tmpdir(), 'claude-wt-pets-transition.log');
const CONFIG_FILE = path.join(__dirname, 'config.json');
const DEFAULT_CONFIG_FILE = path.join(__dirname, 'config.default.json');
const CHARACTERS_DIR = path.join(__dirname, 'characters');
const MAX_SLOTS = 4;
const STALE_MS = 30 * 60 * 1000;
const LOCK_STALE_MS = 5000;
const LOCK_WAIT_MS = 5000;
const TRANSITION_LOG_MAX_BYTES = 512 * 1024;
const TRANSITION_LOG_KEEP_LINES = 1000;

const OWNER_SOURCE = Object.freeze({
  SESSION_MARKER: 'session-marker',
  SESSION_MARKER_SHARED: 'session-marker-shared',
  TITLE_MATCH: 'title-match',
  TAB_TITLE: 'tab-title',
  PROCESS_RECOVERY: 'process-recovery',
  PROCESS_RECOVERY_SHARED: 'process-recovery-shared',
  LAST_KNOWN_GOOD: 'last-known-good',
  FOREGROUND: 'foreground',
  FOREGROUND_SHARED: 'foreground-shared',
  SHARED_UNRESOLVED: 'shared-unresolved',
  UNRESOLVED_DUPLICATE: 'unresolved-duplicate-owner'
});

const OWNER_SOURCE_DIRECT = new Set([
  OWNER_SOURCE.SESSION_MARKER,
  OWNER_SOURCE.TITLE_MATCH
]);

const OWNER_SOURCE_VERIFIED = new Set([
  OWNER_SOURCE.TAB_TITLE
]);

const OWNER_SOURCE_FALLBACK = new Set([
  OWNER_SOURCE.LAST_KNOWN_GOOD
]);

const OWNER_SOURCE_VOLATILE = new Set([
  OWNER_SOURCE.FOREGROUND,
  OWNER_SOURCE.FOREGROUND_SHARED,
  OWNER_SOURCE.SESSION_MARKER_SHARED,
  OWNER_SOURCE.PROCESS_RECOVERY_SHARED
]);

const OWNER_SOURCE_POSITIONAL = new Set([
  'screen-order',
  'screen-order-focus',
  'screen-order-fallback',
  'screen-order-repair',
  'manual-screen-order',
  'unused-visible-window'
]);

const OWNER_SOURCE_UNRESOLVED = new Set([
  OWNER_SOURCE.SHARED_UNRESOLVED,
  OWNER_SOURCE.UNRESOLVED_DUPLICATE,
  'unresolved'
]);

function normalizeOwnerSource(source) {
  return String(source || '').trim();
}

function ownerSourceTier(source) {
  const normalized = normalizeOwnerSource(source);
  if (!normalized) return 'unknown';
  if (OWNER_SOURCE_DIRECT.has(normalized)) return 'direct';
  if (OWNER_SOURCE_VERIFIED.has(normalized)) return 'verified';
  if (OWNER_SOURCE_FALLBACK.has(normalized)) return 'fallback';
  if (OWNER_SOURCE_VOLATILE.has(normalized)) return 'volatile';
  if (OWNER_SOURCE_POSITIONAL.has(normalized)) return 'positional';
  if (OWNER_SOURCE_UNRESOLVED.has(normalized)) return 'unresolved';
  return 'unknown';
}

function isOwnerSourcePersistable(source) {
  return ['direct', 'verified', 'fallback'].includes(ownerSourceTier(source));
}

function isOwnerSourceReusableFromMap(source) {
  return isOwnerSourcePersistable(source);
}

const stateFile = (slot) => path.join(os.tmpdir(), `claude-wt-pets-state-${slot}.json`);
const pidFile = (slot) => path.join(os.tmpdir(), `claude-wt-pets-pet-${slot}.pid`);

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function acquireLock() {
  const deadline = Date.now() + LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    try {
      fs.writeFileSync(LOCK_FILE, String(process.pid), { encoding: 'utf8', flag: 'wx' });
      return () => {
        try { fs.unlinkSync(LOCK_FILE); } catch {}
      };
    } catch (err) {
      if (err.code !== 'EEXIST') return null;
      try {
        const stat = fs.statSync(LOCK_FILE);
        if (Date.now() - stat.mtimeMs > LOCK_STALE_MS) {
          const ownerPid = Number(fs.readFileSync(LOCK_FILE, 'utf8').trim());
          if (!ownerPid || !isProcessAlive(ownerPid)) {
            fs.unlinkSync(LOCK_FILE);
            continue;
          }
        }
      } catch { continue; }
      sleep(20 + Math.floor(Math.random() * 30));
    }
  }
  return null;
}

function readJsonFile(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}

function loadRegistry() {
  try { return readJsonFile(REGISTRY); }
  catch { return {}; }
}

function loadOwnerMap() {
  try {
    const data = readJsonFile(OWNER_MAP);
    return {
      version: 1,
      sessions: data && data.sessions && typeof data.sessions === 'object' ? data.sessions : {},
      slots: data && data.slots && typeof data.slots === 'object' ? data.slots : {}
    };
  } catch {
    return { version: 1, sessions: {}, slots: {} };
  }
}

function loadConfig() {
  const fallback = {
    defaultCharacter: '',
    slotCharacters: {}
  };

  // config.json은 사용자 설정(git 제외), 없으면 저장소 기본값 config.default.json을 읽는다.
  const configPath = fs.existsSync(CONFIG_FILE) ? CONFIG_FILE : DEFAULT_CONFIG_FILE;
  try {
    return { ...fallback, ...JSON.parse(fs.readFileSync(configPath, 'utf8')) };
  } catch {
    return fallback;
  }
}

function characterDirectories() {
  try {
    return fs.readdirSync(CHARACTERS_DIR, { withFileTypes: true })
      .filter(x => x.isDirectory() && !x.name.startsWith('.'))
      .map(x => x.name)
      .filter(name => /^[\p{L}\p{N}_.-]+$/u.test(name) && !name.includes('/') && !name.includes('\\') && !name.includes('..'))
      .sort((a, b) => (a < b ? -1 : (a > b ? 1 : 0)));
  } catch {
    return [];
  }
}

function leadingSlotNumber(name) {
  if (!name || typeof name !== 'string') return 0;
  const match = name.match(/^(\d+)/);
  if (!match) return 0;

  const slot = Number(match[1]);
  return Number.isInteger(slot) && slot >= 1 && slot <= MAX_SLOTS ? slot : 0;
}

function numberedSlotCharacters() {
  const map = {};
  for (const name of characterDirectories()) {
    const slot = leadingSlotNumber(name);
    if (slot && !map[String(slot)]) {
      map[String(slot)] = name;
    }
  }
  return map;
}

function automaticCharacterDirectories() {
  const numbered = numberedSlotCharacters();
  const ordered = [];
  for (let slot = 1; slot <= MAX_SLOTS; slot += 1) {
    const candidate = numbered[String(slot)];
    if (candidate) ordered.push(candidate);
  }
  return ordered;
}

function characterExists(name) {
  if (!name || typeof name !== 'string') return false;
  if (name === '.' || name === '..') return false;
  if (name.startsWith('.')) return false;
  if (name.includes('/') || name.includes('\\') || name.includes('..')) return false;
  if (!/^[\p{L}\p{N}_.-]+$/u.test(name)) return false;
  try {
    return fs.statSync(path.join(CHARACTERS_DIR, name)).isDirectory();
  } catch {
    return false;
  }
}

function automaticCharacterExists(name, slot = 0) {
  if (!characterExists(name)) return false;
  const leading = leadingSlotNumber(name);
  if (!leading) return false;
  return !slot || leading === Number(slot);
}

function resolveCharacter(slot) {
  const slotKey = String(Number(slot));
  const config = loadConfig();
  const numbered = numberedSlotCharacters();
  const envCharacter = process.env.CLAUDE_WT_PETS_CHARACTER;
  const numberedCharacter = numbered[slotKey];
  const slotCharacter = config.slotCharacters && config.slotCharacters[slotKey];
  if (characterExists(envCharacter)) return envCharacter;
  if (characterExists(slotCharacter)) return slotCharacter;
  if (automaticCharacterExists(numberedCharacter, slot)) return numberedCharacter;
  if (characterExists(config.defaultCharacter)) return config.defaultCharacter;

  const automaticFallback = automaticCharacterDirectories()[0];
  if (automaticCharacterExists(automaticFallback)) return automaticFallback;

  return '';
}

function sessionCharacterOverride(slot, sessionId) {
  const slotNumber = positiveInteger(slot);
  if (!slotNumber || !sessionId || !fs.existsSync(stateFile(slotNumber))) return '';

  try {
    const current = readJsonFile(stateFile(slotNumber));
    const currentSessionId = stringValue(current && current.session_id);
    if (!currentSessionId || currentSessionId !== sessionId) return '';

    const candidate = stringValue(current && current.character);
    return characterExists(candidate) ? candidate : '';
  } catch {
    return '';
  }
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value), 'utf8');
  fs.renameSync(tmp, file);
}

function positiveInteger(value) {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : 0;
}

function stripTitleSpinner(s) {
  return s.replace(/^[⠀-⣿✳-✷○-●■-□•·⦿]+\s*/, '');
}

function titlesCompatible(a, b) {
  const left = stripTitleSpinner(stringValue(a).toLowerCase());
  const right = stripTitleSpinner(stringValue(b).toLowerCase());
  if (!left || !right) return true;
  return left === right || left.includes(right) || right.includes(left);
}

function ownerMapStoredTitles(candidate) {
  return [candidate && candidate.window_title, candidate && candidate.tab_title]
    .map(stringValue)
    .filter(Boolean);
}

function ownerMapTitleMatches(candidate, currentTitle) {
  const title = stringValue(currentTitle);
  const storedTitles = ownerMapStoredTitles(candidate);
  if (!title || storedTitles.length === 0) return true;
  return storedTitles.some(stored => titlesCompatible(title, stored));
}

function findProbeWindow(probeWindows, hwnd) {
  const target = positiveInteger(hwnd);
  if (!target) return null;
  return (probeWindows || []).find(w => positiveInteger(w && w.hwnd) === target) || null;
}

function ownerSnapshot(info) {
  if (!info) return {};
  return {
    owner_pid: positiveInteger(info.owner_pid),
    owner_name: info.owner_name || '',
    owner_hwnd: positiveInteger(info.owner_hwnd),
    owner_source: info.owner_source || ''
  };
}

function sameOwner(a, b) {
  return positiveInteger(a && a.owner_pid) === positiveInteger(b && b.owner_pid) &&
    (a && a.owner_name || '') === (b && b.owner_name || '') &&
    positiveInteger(a && a.owner_hwnd) === positiveInteger(b && b.owner_hwnd) &&
    (a && a.owner_source || '') === (b && b.owner_source || '');
}

function ownerRecord(sessionId, info) {
  const slot = positiveInteger(info && info.slot);
  const ownerHwnd = positiveInteger(info && info.owner_hwnd);
  if (!slot || !ownerHwnd) return null;
  const ownerSource = normalizeOwnerSource(info.owner_source);
  if (!isOwnerSourcePersistable(ownerSource)) return null;
  const character = stringValue(info && info.character);

  return {
    session_id: sessionId,
    slot,
    character,
    pet_name: character,
    owner_pid: positiveInteger(info.owner_pid) || null,
    owner_name: info.owner_name || '',
    owner_hwnd: ownerHwnd,
    owner_source: ownerSource,
    window_title: stringValue(info.window_title),
    tab_title: stringValue(info.tab_title),
    session_pid: positiveInteger(info.session_pid) || null,
    session_name: info.session_name || '',
    ts: Date.now()
  };
}

function usableOwnerMapCandidate(candidate, usedHwnds, probeWindows = []) {
  const ownerHwnd = positiveInteger(candidate && candidate.owner_hwnd);
  if (!ownerHwnd || usedHwnds.has(ownerHwnd)) return null;
  const currentWindow = findProbeWindow(probeWindows, ownerHwnd);
  if (currentWindow && !ownerMapTitleMatches(candidate, currentWindow.title)) {
    candidate.window_title = currentWindow.title;
    candidate.tab_title = currentWindow.title;
  }
  return isOwnerSourceReusableFromMap(candidate && candidate.owner_source) ? candidate : null;
}

function ownerMapCandidate(ownerMap, sessionId, slot, usedHwnds = new Set(), sessionPid = 0, probeWindows = []) {
  const bySession = usableOwnerMapCandidate(ownerMap.sessions && ownerMap.sessions[sessionId], usedHwnds, probeWindows);
  if (bySession) return bySession;

  const bySlot = usableOwnerMapCandidate(ownerMap.slots && ownerMap.slots[String(slot)], usedHwnds, probeWindows);
  if (
    bySlot &&
    (
      bySlot.session_id === sessionId ||
      (positiveInteger(sessionPid) && positiveInteger(bySlot.session_pid) === positiveInteger(sessionPid)) ||
      !sessionId
    )
  ) {
    return bySlot;
  }

  return null;
}

function applyOwnerRecord(info, record, source) {
  if (!info || !record) return false;

  const before = ownerSnapshot(info);
  const ownerPid = positiveInteger(record.owner_pid);
  const ownerHwnd = positiveInteger(record.owner_hwnd);

  if (ownerPid) info.owner_pid = ownerPid;
  if (record.owner_name) info.owner_name = record.owner_name;
  if (ownerHwnd) info.owner_hwnd = ownerHwnd;
  if (record.window_title) info.window_title = record.window_title;
  if (record.tab_title) info.tab_title = record.tab_title;
  info.owner_source = normalizeOwnerSource(source || record.owner_source || OWNER_SOURCE.LAST_KNOWN_GOOD);

  return !sameOwner(before, ownerSnapshot(info));
}

function ownerHwndOwners(reg, ownerHwnd) {
  const target = positiveInteger(ownerHwnd);
  if (!target) return [];

  return Object.entries(reg)
    .filter(([, info]) => positiveInteger(info && info.owner_hwnd) === target)
    .sort((a, b) => {
      const slotDiff = positiveInteger(a[1].slot) - positiveInteger(b[1].slot);
      if (slotDiff) return slotDiff;
      return Number(a[1].ts || 0) - Number(b[1].ts || 0);
    });
}

function repairDuplicateOwners(reg, ownerMap) {
  const repairs = [];
  const usedHwnds = new Set();
  const entries = Object.entries(reg)
    .filter(([, info]) => positiveInteger(info && info.owner_hwnd))
    .sort((a, b) => {
      const slotDiff = positiveInteger(a[1].slot) - positiveInteger(b[1].slot);
      if (slotDiff) return slotDiff;
      return Number(a[1].ts || 0) - Number(b[1].ts || 0);
    });

  for (const [sessionId, info] of entries) {
    const ownerHwnd = positiveInteger(info.owner_hwnd);
    if (!usedHwnds.has(ownerHwnd)) {
      usedHwnds.add(ownerHwnd);
      continue;
    }

    const duplicateOwners = ownerHwndOwners(reg, ownerHwnd);
    const liveSharedWindowTabs = duplicateOwners.length > 1 &&
      duplicateOwners.every(([, value]) => {
        const sessionPid = positiveInteger(value && value.session_pid);
        if (!sessionPid || !isProcessAlive(sessionPid)) return false;
        const expectedName = value.session_name || 'claude';
        return expectedName === 'claude';
      });
    if (liveSharedWindowTabs) {
      usedHwnds.add(ownerHwnd);
      continue;
    }

    const previous = ownerMapCandidate(ownerMap, sessionId, info.slot, usedHwnds, info.session_pid);
    if (previous && applyOwnerRecord(info, previous, OWNER_SOURCE.LAST_KNOWN_GOOD)) {
      const repairedOwnerHwnd = positiveInteger(info.owner_hwnd);
      usedHwnds.add(repairedOwnerHwnd);
      repairs.push({
        session_id: sessionId,
        slot: info.slot,
        action: 'restore-last-known-owner',
        owner_hwnd: repairedOwnerHwnd
      });
      continue;
    }

    delete info.owner_hwnd;
    info.owner_source = OWNER_SOURCE.UNRESOLVED_DUPLICATE;
    repairs.push({ session_id: sessionId, slot: info.slot, action: 'clear-duplicate-owner' });
  }

  return repairs;
}

function restoreOwnerIfMissing(reg, info, sessionId, ownerMap, probeWindows = []) {
  if (positiveInteger(info && info.owner_hwnd)) return false;

  const usedHwnds = new Set(
    Object.entries(reg)
      .filter(([sid, value]) => sid !== sessionId && positiveInteger(value && value.owner_hwnd))
      .map(([, value]) => positiveInteger(value.owner_hwnd))
      .filter(Boolean)
  );
  const previous = ownerMapCandidate(ownerMap, sessionId, info && info.slot, usedHwnds, info && info.session_pid, probeWindows);
  return previous ? applyOwnerRecord(info, previous, OWNER_SOURCE.LAST_KNOWN_GOOD) : false;
}

function saveOwnerMap(ownerMap, reg, sessionId, info) {
  const record = ownerRecord(sessionId, info);
  if (!record) return false;

  if (ownerHwndOwners(reg, record.owner_hwnd).length !== 1) return false;

  ownerMap.sessions[sessionId] = record;
  ownerMap.slots[String(record.slot)] = record;
  ownerMap.updated_at = new Date().toISOString();
  writeJsonAtomic(OWNER_MAP, ownerMap);
  return true;
}

function syncOwnerFieldsToState(sessionId, info) {
  const slot = positiveInteger(info && info.slot);
  if (!slot || !fs.existsSync(stateFile(slot))) return false;

  try {
    const current = readJsonFile(stateFile(slot));
    const payload = {
      ...current,
      ts: nextStateTimestamp(slot),
      session_id: current.session_id || sessionId,
      slot,
      character: info.character || current.character || '',
      owner_pid: positiveInteger(info.owner_pid) || null,
      owner_name: info.owner_name || '',
      owner_hwnd: positiveInteger(info.owner_hwnd) || null,
      owner_source: info.owner_source || '',
      window_title: info.window_title || current.window_title || '',
      session_pid: positiveInteger(info.session_pid) || null,
      session_name: info.session_name || '',
      tab_title: info.tab_title || current.tab_title || ''
    };
    writeJsonAtomic(stateFile(slot), payload);
    return true;
  } catch {
    return false;
  }
}

function persistRepairedOwners(repairs, ownerMap, reg, currentSessionId) {
  for (const repair of repairs) {
    const repairedInfo = reg[repair.session_id];
    if (!repairedInfo) continue;
    if (repair.session_id !== currentSessionId) {
      syncOwnerFieldsToState(repair.session_id, repairedInfo);
    }
    saveOwnerMap(ownerMap, reg, repair.session_id, repairedInfo);
  }
}

const ROTATION_COOLDOWN_MS = 60000;
let lastRotationTime = 0;

function rotateTransitionLogIfNeeded() {
  try {
    if (Date.now() - lastRotationTime < ROTATION_COOLDOWN_MS) return;
    if (!fs.existsSync(TRANSITION_LOG)) return;
    if (fs.statSync(TRANSITION_LOG).size <= TRANSITION_LOG_MAX_BYTES) return;

    const lines = fs.readFileSync(TRANSITION_LOG, 'utf8').split(/\r?\n/).filter(Boolean);
    const kept = lines.slice(-TRANSITION_LOG_KEEP_LINES);
    fs.writeFileSync(TRANSITION_LOG, kept.length ? kept.join(os.EOL) + os.EOL : '', 'utf8');
    lastRotationTime = Date.now();
  } catch {}
}

function appendTransitionLog(entry) {
  try {
    rotateTransitionLogIfNeeded();
    fs.appendFileSync(TRANSITION_LOG, JSON.stringify({
      ts: new Date().toISOString(),
      source: 'notifier',
      ...entry
    }) + os.EOL, 'utf8');
  } catch {}
}

function nextStateTimestamp(slot) {
  let previous = 0;
  try {
    previous = Number(readJsonFile(stateFile(slot)).ts) || 0;
  } catch {}
  return Math.max(Date.now(), previous + 1);
}

function isProcessAlive(pid) {
  const n = Number(pid);
  if (!Number.isInteger(n) || n <= 0) return false;
  try {
    process.kill(n, 0);
    return true;
  } catch (err) {
    return err && err.code === 'EPERM';
  }
}

function isPetProcessAlive(slot) {
  try {
    const file = pidFile(slot);
    if (!fs.existsSync(file)) return false;
    const petPid = Number(fs.readFileSync(file, 'utf8').trim());
    return isProcessAlive(petPid);
  } catch {
    return false;
  }
}

function readOwnerProbe() {
  try {
    const raw = process.env.CLAUDE_WT_PETS_OWNER_PROBE;
    if (!raw) return null;
    const probe = JSON.parse(raw);
    return {
      foreground_hwnd: positiveInteger(probe.foreground_hwnd),
      foreground_pid: positiveInteger(probe.foreground_pid),
      foreground_name: probe.foreground_name || '',
      matched_hwnd: positiveInteger(probe.matched_hwnd),
      tab_title: probe.tab_title || '',
      visible_windows: Array.isArray(probe.visible_windows) ? probe.visible_windows : []
    };
  } catch {
    return null;
  }
}

function usedOwnerHwnds(reg, excludeSessionId) {
  const used = new Set();
  for (const [sid, info] of Object.entries(reg)) {
    if (sid === excludeSessionId) continue;
    const hwnd = positiveInteger(info && info.owner_hwnd);
    if (hwnd) used.add(hwnd);
  }
  return used;
}

function resolveOwnerFromProbe(probe, reg, ownerMap, sessionId, slot, sessionProcess) {
  if (!probe) return null;

  const used = usedOwnerHwnds(reg, sessionId);
  const probeWindows = probe.visible_windows
    .map(w => ({
      hwnd: positiveInteger(w.hwnd),
      pid: positiveInteger(w.pid),
      left: w.left || 0,
      top: w.top || 0,
      title: stringValue(w.title)
    }))
    .filter(w => w.hwnd > 0);
  const probeHwnds = new Set(probeWindows.map(w => w.hwnd));
  const activeSlots = new Set(
    Object.values(reg)
      .map(info => positiveInteger(info && info.slot))
      .filter(Boolean)
  ).size;
  const mergedWindows = probeWindows.length > 0 && activeSlots > 0 && probeWindows.length < activeSlots;

  if (probe.matched_hwnd && probeHwnds.has(probe.matched_hwnd)) {
    const matchedUsed = used.has(probe.matched_hwnd);
    if (matchedUsed && !mergedWindows) return null;
    const win = probeWindows.find(w => w.hwnd === probe.matched_hwnd);
    return {
      pid: (win && win.pid) || 0,
      name: 'WindowsTerminal',
      hwnd: probe.matched_hwnd,
      window_title: (win && win.title) || probe.tab_title || '',
      tab_title: probe.tab_title || '',
      source: matchedUsed ? OWNER_SOURCE.SESSION_MARKER_SHARED : OWNER_SOURCE.TITLE_MATCH
    };
  }

  const sessionPid = positiveInteger(sessionProcess && sessionProcess.pid);
  const candidate = ownerMapCandidate(ownerMap, sessionId, slot, used, sessionPid, probeWindows);
  if (candidate) {
    const candidateHwnd = positiveInteger(candidate.owner_hwnd);
    if (candidateHwnd && !used.has(candidateHwnd) && probeHwnds.has(candidateHwnd)) {
      const win = probeWindows.find(w => w.hwnd === candidateHwnd);
      return {
        pid: positiveInteger(candidate.owner_pid) || (win && win.pid) || 0,
        name: candidate.owner_name || 'WindowsTerminal',
        hwnd: candidateHwnd,
        window_title: (win && win.title) || candidate.window_title || '',
        tab_title: candidate.tab_title || '',
        source: OWNER_SOURCE.LAST_KNOWN_GOOD
      };
    }
  }

  return null;
}

function shouldUpdateOwnerForHook(hookName) {
  return hookName === 'SessionStart' ||
    hookName === 'UserPromptSubmit' ||
    hookName === 'PreToolUse';
}

function resolveSessionProcess(event) {
  const explicitPid = Number(process.env.CLAUDE_WT_PETS_SESSION_PID || event.session_pid || event.sessionPid);
  if (Number.isInteger(explicitPid) && explicitPid > 0) {
    return {
      pid: explicitPid,
      name: process.env.CLAUDE_WT_PETS_SESSION_NAME || event.session_name || event.sessionName || 'claude'
    };
  }

  return null;
}

function stringValue(value) {
  if (typeof value !== 'string') return '';
  const trimmed = value.trim();
  return trimmed ? trimmed : '';
}

function directSessionId(event) {
  const candidates = [
    process.env.CLAUDE_WT_PETS_SESSION_ID,
    event.session_id,
    event.sessionId,
    event.session && event.session.id,
    process.env.CLAUDE_SESSION_ID
  ];

  for (const candidate of candidates) {
    const value = stringValue(candidate);
    if (value) return value;
  }

  const transcriptPath = stringValue(event.transcript_path || event.transcriptPath);
  if (transcriptPath) {
    return `transcript:${path.normalize(transcriptPath).toLowerCase()}`;
  }

  return '';
}

function fallbackSessionId(owner, sessionProcess) {
  if (owner && Number.isInteger(Number(owner.pid)) && Number(owner.pid) > 0) {
    return `owner:${owner.pid}`;
  }
  if (sessionProcess && Number.isInteger(Number(sessionProcess.pid)) && Number(sessionProcess.pid) > 0) {
    return `session:${sessionProcess.pid}`;
  }
  return `fallback:${process.pid}:${Date.now()}`;
}

function findSessionByProcess(reg, sessionProcess) {
  const sessionPid = Number(sessionProcess && sessionProcess.pid);
  if (!Number.isInteger(sessionPid) || sessionPid <= 0) return '';

  return Object.entries(reg)
    .filter(([, info]) => Number(info && info.session_pid) === sessionPid)
    .sort((a, b) => Number(b[1].ts || 0) - Number(a[1].ts || 0))
    .map(([sessionId]) => sessionId)[0] || '';
}

function resolveSessionId(event, sessionProcess, reg) {
  const direct = directSessionId(event);
  const fallback = fallbackSessionId(null, sessionProcess);

  if (direct) {
    if (!reg[direct] && fallback !== direct && reg[fallback]) {
      reg[direct] = reg[fallback];
      delete reg[fallback];
    }
    return direct;
  }

  const byProcess = findSessionByProcess(reg, sessionProcess);
  if (byProcess) return byProcess;

  return fallback;
}

function cleanStale(reg) {
  const now = Date.now();
  for (const [sid, info] of Object.entries(reg)) {
    const slot = Number(info && info.slot);
    const ts = Number(info && info.ts);
    if (!slot || slot < 1 || slot > MAX_SLOTS || !ts) {
      delete reg[sid];
      continue;
    }
    const ownerPid = Number(info && info.owner_pid);
    const sessionPid = Number(info && info.session_pid);
    const hasOwnerPid = Number.isFinite(ownerPid) && ownerPid > 0;
    const hasSessionPid = Number.isFinite(sessionPid) && sessionPid > 0;
    const ownerGone = hasOwnerPid && !isProcessAlive(ownerPid);
    const sessionAlive = hasSessionPid && isProcessAlive(sessionPid);
    const sessionGone = hasSessionPid && !sessionAlive;
    if (now - ts > STALE_MS) {
      if (sessionAlive) {
        info.ts = now;
        appendTransitionLog({
          action: 'clean-keep-live-session-stale',
          session_id: sid,
          slot,
          session_pid: sessionPid,
          detail: `age_ms=${now - ts}`
        });
        continue;
      }
      try { fs.unlinkSync(stateFile(slot)); } catch {}
      try { fs.unlinkSync(pidFile(slot)); } catch {}
      delete reg[sid];
      continue;
    }
    const ownerOnlyGone = ownerGone && !hasSessionPid;
    const stateExists = fs.existsSync(stateFile(slot));
    const petPidExists = fs.existsSync(pidFile(slot));
    const missingState = !stateExists && now - ts > 5000 && !sessionAlive;
    const missingPet = !hasOwnerPid && !petPidExists && now - ts > 5000 && !sessionAlive;
    const liveSessionMissingRuntime = sessionAlive && now - ts > 5000 && (!stateExists || !petPidExists);
    if (liveSessionMissingRuntime) {
      info.ts = now;
      appendTransitionLog({
        action: 'clean-keep-live-session-runtime-missing',
        session_id: sid,
        slot,
        session_pid: sessionPid,
        detail: `stateExists=${stateExists};pidExists=${petPidExists};hasOwnerPid=${hasOwnerPid}`
      });
      continue;
    }
    if (ownerOnlyGone || sessionGone || missingState || missingPet) {
      if (isPetProcessAlive(slot)) {
        appendTransitionLog({
          action: 'clean-skip-pet-alive',
          session_id: sid,
          slot,
          detail: `sessionGone=${sessionGone};ownerGone=${ownerOnlyGone};missingState=${missingState};missingPet=${missingPet}`
        });
        continue;
      }
      try { fs.unlinkSync(stateFile(slot)); } catch {}
      try { fs.unlinkSync(pidFile(slot)); } catch {}
      delete reg[sid];
    }
  }
}

function findSlot(reg) {
  const used = new Set(Object.values(reg).map(v => v.slot));
  for (let i = 1; i <= MAX_SLOTS; i++) {
    if (!used.has(i)) return i;
  }
  return null;
}

function ensureSession(reg, sessionId, sessionProcess) {
  cleanStale(reg);
  if (!reg[sessionId]) {
    const slot = findSlot(reg);
    if (!slot) return null;
    reg[sessionId] = { slot, ts: Date.now() };
  } else {
    reg[sessionId].ts = Date.now();
  }

  const stateCharacter = sessionCharacterOverride(reg[sessionId].slot, sessionId);
  if (stateCharacter) {
    reg[sessionId].character = stateCharacter;
  } else {
    reg[sessionId].character = resolveCharacter(reg[sessionId].slot);
  }

  if (sessionProcess && sessionProcess.pid) {
    reg[sessionId].session_pid = sessionProcess.pid;
    reg[sessionId].session_name = sessionProcess.name || '';
  }

  return reg[sessionId];
}

function applyOwner(info, owner) {
  if (!info || !owner) return;
  if (owner.pid) {
    info.owner_pid = owner.pid;
    info.owner_name = owner.name || '';
  }
  if (owner.hwnd) {
    info.owner_hwnd = owner.hwnd;
  }
  if (owner.window_title && !owner.window_title.startsWith('__claude_wt_pets_')) {
    info.window_title = owner.window_title;
  }
  if (owner.tab_title) {
    info.tab_title = owner.tab_title;
  }
  if (owner.source) {
    info.owner_source = owner.source;
  }
}

function shouldSkipStateWrite(hookName, reg, sessionId) {
  if (hookName !== 'SessionStart') return false;

  const info = reg[sessionId];
  const slot = positiveInteger(info && info.slot);
  if (!slot || !fs.existsSync(stateFile(slot))) return false;

  try {
    const current = readJsonFile(stateFile(slot));
    return stringValue(current && current.session_id) === stringValue(sessionId);
  } catch {
    return false;
  }
}

function stateForHook(hookName, event) {
  if (hookName === 'SessionStart') {
    return { state: 'idle', message: '' };
  }
  if (hookName === 'Stop') {
    return { state: 'done', message: '답변 완료' };
  }
  if (hookName === 'Notification') {
    const message = stringValue(event.message);
    if (message.toLowerCase() === 'claude is waiting for your input') {
      return { state: 'notification', message: '확인이 필요합니다.' };
    }
    return { state: 'notification', message: message || '확인이 필요합니다.' };
  }
  if (hookName === 'PreToolUse') {
    return { state: 'thinking', message: event.tool_name || '' };
  }
  if (hookName === 'PostToolUse') {
    return { state: 'thinking', message: event.tool_name || '' };
  }
  if (hookName === 'UserPromptSubmit') {
    return { state: 'thinking', message: '' };
  }
  if (hookName === 'PostToolUseFailure' || hookName === 'StopFailure') {
    return { state: 'error', message: event.message || event.error || '작업 실행 중 문제가 발생했습니다.' };
  }
  return null;
}

const chunks = [];
process.stdin.on('data', d => chunks.push(d));
process.stdin.on('end', () => {
  let event = {};
  try { event = JSON.parse(Buffer.concat(chunks).toString().replace(/^﻿/, '').trim()); } catch {}

  const hookName = process.argv[2];
  if (!hookName) process.exit(1);

  const release = acquireLock();
  if (!release) {
    appendTransitionLog({
      action: 'lock-acquire-failed',
      hook: hookName,
      detail: `timeout=${LOCK_WAIT_MS}ms`
    });
    process.exit(0);
  }

  try {
    const reg = loadRegistry();
    const ownerMap = loadOwnerMap();
    const stateData = stateForHook(hookName, event);
    if (!stateData) {
      appendTransitionLog({
        action: 'skip-hook-no-state',
        hook: hookName,
        detail: hookName === 'Notification' ? (stringValue(event.message) || '(empty)') : ''
      });
      return;
    }

    const probe = shouldUpdateOwnerForHook(hookName) ? readOwnerProbe() : null;
    const sessionProcess = resolveSessionProcess(event);
    const sessionId = resolveSessionId(event, sessionProcess, reg);
    const previousOwner = ownerSnapshot(reg[sessionId]);
    const info = ensureSession(reg, sessionId, sessionProcess);
    if (!info) {
      writeJsonAtomic(REGISTRY, reg);
      appendTransitionLog({
        action: 'ignore-session-over-capacity',
        hook: hookName,
        session_id: sessionId,
        session_pid: Number(sessionProcess && sessionProcess.pid) || null
      });
      return;
    }

    if (probe) {
      const owner = resolveOwnerFromProbe(probe, reg, ownerMap, sessionId, info.slot, sessionProcess);
      const existingHwnd = positiveInteger(info.owner_hwnd);
      let keepExisting = false;
      if (owner && existingHwnd) {
        const TIER_RANK = { direct: 0, verified: 1, fallback: 2, positional: 3, volatile: 4, unresolved: 5, unknown: 6 };
        const currentRank = TIER_RANK[ownerSourceTier(info.owner_source)] ?? 6;
        const newRank = TIER_RANK[ownerSourceTier(owner.source)] ?? 6;
        if (newRank > currentRank) {
          const probeHwnds = new Set((probe.visible_windows || []).map(w => positiveInteger(w.hwnd)).filter(Boolean));
          keepExisting = probeHwnds.has(existingHwnd);
        }
      }
      if (!keepExisting) {
        applyOwner(info, owner);
      }
      const probeWindows = (probe.visible_windows || []).map(w => ({
        hwnd: positiveInteger(w.hwnd),
        pid: positiveInteger(w.pid),
        title: stringValue(w.title)
      }));
      if (!owner) {
        restoreOwnerIfMissing(reg, info, sessionId, ownerMap, probeWindows);
      }
      if (probe.tab_title) {
        info.tab_title = probe.tab_title;
      }
    } else {
      const slot = positiveInteger(info && info.slot);
      if (slot && fs.existsSync(stateFile(slot))) {
        try {
          const current = readJsonFile(stateFile(slot));
          const stateOwnerHwnd = positiveInteger(current.owner_hwnd);
          const stateOwnerSource = current.owner_source || '';
          if (stateOwnerHwnd && (
            stateOwnerHwnd !== positiveInteger(info.owner_hwnd) ||
            stateOwnerSource !== (info.owner_source || '')
          )) {
            info.owner_hwnd = stateOwnerHwnd;
            if (positiveInteger(current.owner_pid)) info.owner_pid = current.owner_pid;
            if (current.owner_name) info.owner_name = current.owner_name;
            info.owner_source = stateOwnerSource;
          }
          if (!info.tab_title && current.tab_title) {
            info.tab_title = current.tab_title;
          }
          if (!info.window_title && current.window_title) {
            info.window_title = current.window_title;
          }
        } catch {}
      }
      if (!positiveInteger(info.owner_hwnd)) {
        restoreOwnerIfMissing(reg, info, sessionId, ownerMap);
      }
    }

    {
      const repairs = repairDuplicateOwners(reg, ownerMap);
      const ownerChanged = !sameOwner(previousOwner, ownerSnapshot(info));
      let skipStateWrite = shouldSkipStateWrite(hookName, reg, sessionId) && !ownerChanged && repairs.length === 0;

      if (!skipStateWrite && hookName === 'Notification' && stateData.state === 'notification') {
        const s = positiveInteger(info.slot);
        if (s && fs.existsSync(stateFile(s))) {
          try {
            const cur = readJsonFile(stateFile(s));
            if (cur.state === 'done' &&
                stringValue(event.message).toLowerCase() === 'claude is waiting for your input') {
              skipStateWrite = true;
              appendTransitionLog({
                action: 'skip-notification-over-done',
                hook: hookName,
                session_id: sessionId,
                slot: s,
                state: cur.state,
                notification_message: stringValue(event.message) || '(empty)',
                session_pid: Number(info.session_pid) || null
              });
            }
          } catch {}
        }
      }
      for (const repair of repairs) {
        appendTransitionLog({
          action: repair.action,
          hook: hookName,
          session_id: repair.session_id,
          slot: repair.slot,
          owner_hwnd: repair.owner_hwnd || null
        });
      }

      if (skipStateWrite) {
        writeJsonAtomic(REGISTRY, reg);
        persistRepairedOwners(repairs, ownerMap, reg, sessionId);
        saveOwnerMap(ownerMap, reg, sessionId, info);
        appendTransitionLog({
          action: 'skip-state-write',
          hook: hookName,
          session_id: sessionId,
          slot: info.slot,
          state: stateData.state,
          character: info.character || '',
          session_pid: Number(info.session_pid) || null
        });
        return;
      }

      const slot = Number(info.slot);
      const ts = nextStateTimestamp(slot);
      info.ts = ts;
      const payload = {
        state: stateData.state,
        message: stateData.message,
        ts,
        session_id: sessionId,
        slot,
        character: info.character || '',
        owner_pid: Number(info.owner_pid) || null,
        owner_name: info.owner_name || '',
        owner_hwnd: Number(info.owner_hwnd) || null,
        owner_source: info.owner_source || '',
        window_title: info.window_title || '',
        session_pid: Number(info.session_pid) || null,
        session_name: info.session_name || '',
        tab_title: info.tab_title || ''
      };

      writeJsonAtomic(REGISTRY, reg);
      writeJsonAtomic(stateFile(slot), payload);
      persistRepairedOwners(repairs, ownerMap, reg, sessionId);
      saveOwnerMap(ownerMap, reg, sessionId, info);
      appendTransitionLog({
        action: 'write-state',
        hook: hookName,
        session_id: sessionId,
        slot,
        state: payload.state,
        character: payload.character,
        payload_ts: payload.ts,
        owner_name: payload.owner_name || '',
        owner_hwnd: payload.owner_hwnd || null,
        owner_source: payload.owner_source || '',
        window_title: payload.window_title || '',
        session_pid: payload.session_pid || null,
        ...(hookName === 'Notification' ? { notification_message: stringValue(event.message) || '(empty)' } : {})
      });
    }
  } finally {
    release();
  }
});
