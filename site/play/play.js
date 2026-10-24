// The playground: one source, three renderers in workers, one width.
// The width is the terminal's columns; renderers that take a limit get it minus 2, like `mercat -w`.
(() => {
  const root = document.getElementById('try');
  if (!root) return;
  const $ = (s) => root.querySelector(s);
  const src = $('#play-src');
  const term = $('.term');
  const grip = $('.grip');
  const colsOut = root.querySelectorAll('[data-cols]');
  const MIN = 24, MAX = 200, TIMEOUT = 5000;

  const PRESETS = {
    rails: `flowchart TD
  A --> B & C
  B --> D & E
  C --> D & E
  D --> F & G
  E --> F & G
  F --> H
  G --> H
  A -.-> H`,
    ci: `flowchart LR
  Start([Start]) --> Parse[Parse]
  Parse --> A[Lint] & B[Typecheck] & C[Test] & D[Build]
  A & B & C & D --> Gate{All green?}
  Gate -->|no| Fix[Fix code]
  Fix --> Parse
  Gate -->|yes| Deploy[Deploy]
  Deploy --> Smoke{Smoke ok?}
  Smoke -->|no| Rollback[Rollback] --> Fix
  Smoke -->|yes| Done([Done])`,
    nested: `flowchart LR
    P[Alpha and Bravo records] --> Q[Delta Vault account]
    subgraph Inner["Inner: Delta Co"]
        Q --> M[Hidden fields, seeds and tokens]
        M --> N[Digest node]
    end
    subgraph Outer["Open: Ledger on Echo Network"]
        K[Digest, sender, receiver and entry details]
    end
    N -->|Owner asks for public release| K
    M -->|After device verification| V[Remote client]
    K -->|Verify digest and status| V`,
  };

  // ---------- width ----------
  const probe = document.createElement('span');
  probe.className = 'probe';
  probe.textContent = '0'.repeat(100);
  term.querySelector('.term-out').appendChild(probe);
  const cellW = () => probe.getBoundingClientRect().width / 100 || 8;
  const pre = term.querySelector('.term-out');
  const chrome = () => { const cs = getComputedStyle(pre); return parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight); };
  const fits = () => Math.max(MIN, Math.min(MAX, Math.floor((root.querySelector('.term-lane').clientWidth - chrome()) / cellW())));
  let cols = 80;

  function setCols(n, rerender = true) {
    cols = Math.max(MIN, Math.min(fits(), Math.round(n)));
    root.style.setProperty('--cols', cols);
    colsOut.forEach((o) => { o.textContent = cols; });
    grip.setAttribute('aria-valuenow', cols);
    grip.setAttribute('aria-valuemax', fits());
    if (rerender) schedule(0);
  }

  grip.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    grip.setPointerCapture(e.pointerId);
    const left = term.getBoundingClientRect().left, w = cellW(), c = chrome();
    const move = (ev) => setCols((ev.clientX - left - c + 7) / w);
    const up = () => { grip.removeEventListener('pointermove', move); grip.removeEventListener('pointerup', up); root.classList.remove('dragging'); share(); };
    root.classList.add('dragging');
    grip.addEventListener('pointermove', move);
    grip.addEventListener('pointerup', up);
  });
  grip.addEventListener('keydown', (e) => {
    const step = e.shiftKey ? 10 : 1;
    const to = { ArrowLeft: cols - step, ArrowRight: cols + step, Home: MIN, End: fits() }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    setCols(to);
    share();
  });
  new ResizeObserver(() => { if (cols > fits()) setCols(fits()); }).observe(root.querySelector('.term-lane'));

  // ---------- renderers ----------
  const engines = [...root.querySelectorAll('[data-engine]')].map((el) => ({
    name: el.dataset.engine, el, out: el.querySelector('.out'), note: el.querySelector('.note'),
    worker: null, seq: 0, busy: false, queued: false, timer: 0,
  }));

  function spawn(eng) {
    eng.worker?.terminate();
    eng.worker = new Worker(`play/worker.js?e=${eng.name}`, { type: 'module' });
    eng.worker.onmessage = ({ data }) => done(eng, data);
    eng.busy = false;
  }

  function send(eng) {
    if (eng.busy) { eng.queued = true; return; }
    eng.busy = true; eng.queued = false;
    const id = ++eng.seq;
    if (eng.el.dataset.state === 'idle') eng.el.dataset.state = 'loading';
    eng.worker.postMessage({ id, src: src.value, width: Math.max(cols - 2, 1) });
    clearTimeout(eng.timer);
    eng.timer = setTimeout(() => {
      spawn(eng);
      show(eng, { error: `Stopped: took longer than ${TIMEOUT / 1000} seconds.` });
    }, TIMEOUT);
  }

  function done(eng, data) {
    if (data.id !== eng.seq) return;
    clearTimeout(eng.timer);
    eng.busy = false;
    if (data.dead) spawn(eng);
    show(eng, data);
    if (eng.queued) send(eng);
  }

  function show(eng, r) {
    eng.el.dataset.state = r.error ? 'error' : 'ok';
    eng.out.textContent = r.error ? r.error : r.text.replace(/\s+$/, '');
    const width = r.text ? Math.max(0, ...r.text.split('\n').map((l) => [...l].length)) : 0;
    const notes = [];
    if (r.warnings) notes.push(...r.warnings.split('\n').map((w) => w.replace(/^mermaid: /, '')));
    if (eng.name !== 'mercat' && !r.error && width > cols) notes.push(`${width} columns wide: wider than the ${cols}-column terminal.`);
    eng.note.textContent = notes.join('\n');
  }

  let debounce = 0;
  function schedule(ms) {
    clearTimeout(debounce);
    debounce = setTimeout(() => engines.forEach((eng) => eng.worker && send(eng)), ms);
  }

  // ---------- source, presets, sharing ----------
  const enc = (s) => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const dec = (s) => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0)));
  function share() {
    const h = `#try=${enc(src.value)}&w=${cols}`;
    if (h.length < 6000) history.replaceState(null, '', h);
  }

  root.querySelectorAll('[data-preset]').forEach((b) => b.addEventListener('click', () => {
    src.value = PRESETS[b.dataset.preset];
    root.querySelectorAll('[data-preset]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
    schedule(0); share();
  }));
  src.addEventListener('input', () => {
    root.querySelectorAll('[data-preset]').forEach((x) => x.setAttribute('aria-pressed', 'false'));
    schedule(150); share();
  });

  const hash = new URLSearchParams(location.hash.slice(1));
  let initial = PRESETS.ci;
  try { if (hash.get('try')) initial = dec(hash.get('try')); } catch {}
  src.value = initial;
  if (initial === PRESETS.ci) root.querySelector('[data-preset="ci"]').setAttribute('aria-pressed', 'true');
  setCols(Number(hash.get('w')) || Math.min(80, fits()), false);
  if (hash.get('try')) root.scrollIntoView();

  // the renderers load only when the playground comes near the screen
  const wake = (el, names) => {
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      engines.filter((eng) => names.includes(eng.name)).forEach((eng) => { spawn(eng); send(eng); });
    }, { rootMargin: '300px' });
    io.observe(el);
  };
  wake(term, ['mercat']);
  wake(root.querySelector('.cmp'), ['mermaid-ascii', 'beautiful-mermaid']);
})();
