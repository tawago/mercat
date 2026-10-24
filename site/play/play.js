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
    layers: `graph LR
    subgraph Frontend["Frontend Layer"]
        A["Web Server"]
        B["Load Balancer"]
    end
    subgraph Backend["Backend Layer"]
        C["API Gateway"]
        D["Service Mesh"]
    end
    subgraph Data["Data Layer"]
        E["Database"]
        F["Cache"]
    end
    A --> C
    B --> C
    C --> E
    D --> F`,
    wide: `flowchart LR
  Ingest[Ingest raw events] --> Parse[Parse and validate]
  Parse --> Enrich[Enrich with user data]
  Enrich --> Dedupe[Remove duplicates]
  Dedupe --> Agg[Aggregate per hour]
  Agg --> Store[(Write to warehouse)]
  Store --> Report[Build daily report]
  Report --> Send([Email the team])
  Parse -->|invalid| Quarantine[Quarantine bad rows]
  Quarantine --> Alert([Page the on-call])`,
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
  const widthIn = $('#ctl-w');

  function setCols(n, rerender = true) {
    cols = Math.max(MIN, Math.min(fits(), Math.round(n)));
    root.style.setProperty('--cols', cols);
    colsOut.forEach((o) => { o.textContent = cols; });
    grip.setAttribute('aria-valuenow', cols);
    grip.setAttribute('aria-valuemax', fits());
    widthIn.max = fits();
    widthIn.value = cols;
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
  widthIn.addEventListener('input', () => setCols(Number(widthIn.value)));
  widthIn.addEventListener('change', () => share());
  new ResizeObserver(() => { if (cols > fits()) setCols(fits()); else widthIn.max = fits(); }).observe(root.querySelector('.term-lane'));

  // ---------- text size ----------
  const SIZES = [6, 7, 8, 9, 10, 11, 12];
  const fsOut = $('#ctl-fs');
  let size = 10;
  try { size = Number(localStorage.getItem('mercat-play-size')) || size; } catch {}
  function setSize(px) {
    size = px;
    root.style.setProperty('--cell', `${px}px`);
    fsOut.textContent = `${px}px`;
    root.querySelector('[data-font="-1"]').disabled = px === SIZES[0];
    root.querySelector('[data-font="1"]').disabled = px === SIZES[SIZES.length - 1];
    try { localStorage.setItem('mercat-play-size', String(px)); } catch {}
    setCols(cols, false);
  }
  root.querySelectorAll('[data-font]').forEach((b) => b.addEventListener('click', () => {
    const i = SIZES.indexOf(size) + Number(b.dataset.font);
    if (SIZES[i]) setSize(SIZES[i]);
  }));

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

  // ---------- highlighting ----------
  const hl = $('.editor .hl code');
  const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const TOKENS = new RegExp([
    /(%%.*)/,                                                                   // comment
    /("(?:[^"\\]|\\.)*")/,                                                  // string
    /(\|[^|\n]*\|)/,                                                         // edge label
    /((?:[<ox]?(?:-{2,}|={2,}|-\.+-|~{3,})[>ox]?)|(?:--?\.?-?>)|&)/,           // link operator
    /(\(\[|\[\(|\(\(|\)\)|\]\)|\)\]|\[\[|\]\]|\{\{|\}\}|[\[\](){}>])/, // shape bracket
    /\b(flowchart|graph|subgraph|end|direction|classDef|class|style|linkStyle|click)\b/, // keyword
    /\b(TD|TB|BT|LR|RL)\b/,                                                   // direction
  ].map((r) => r.source).join('|'), 'g');
  const ids = (t) => t.split(/([A-Za-z_][\w-]*)/).map((p, i) => (i % 2 ? `<span class="i">${p}</span>` : esc(p))).join('');
  function paintLine(line) {
    let out = '', depth = 0, last = 0;
    for (const m of line.matchAll(TOKENS)) {
      const plain = line.slice(last, m.index);
      out += depth ? `<span class="t">${esc(plain)}</span>` : ids(plain);
      const [tok, c, str, lab, link, br, kw, dir] = m;
      if (c) out += `<span class="c">${esc(c)}</span>`;
      else if (str) out += `<span class="s">${esc(str)}</span>`;
      else if (lab) out += `<span class="a">|</span><span class="t">${esc(lab.slice(1, -1))}</span><span class="a">|</span>`;
      else if (link && !depth) out += `<span class="a">${esc(link)}</span>`;
      else if (br) {
        if (/^[[({]/.test(br)) depth++; else if (br !== '>') depth = Math.max(0, depth - 1);
        out += `<span class="d">${esc(br)}</span>`;
      } else if ((kw || dir) && !depth) out += `<span class="k">${tok}</span>`;
      else out += depth ? `<span class="t">${esc(tok)}</span>` : esc(tok);
      last = m.index + tok.length;
    }
    const rest = line.slice(last);
    return out + (depth ? `<span class="t">${esc(rest)}</span>` : ids(rest));
  }
  function paint() {
    hl.innerHTML = src.value.split('\n').map(paintLine).join('\n') + '\n';
    syncScroll();
  }
  const hlPre = $('.editor .hl');
  const syncScroll = () => { hlPre.scrollTop = src.scrollTop; hlPre.scrollLeft = src.scrollLeft; };
  src.addEventListener('scroll', syncScroll);

  // ---------- source, presets, sharing ----------
  const enc = (s) => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const dec = (s) => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0)));
  function share() {
    const h = `#try=${enc(src.value)}&w=${cols}`;
    if (h.length < 6000) history.replaceState(null, '', h);
  }

  root.querySelectorAll('[data-preset]').forEach((b) => b.addEventListener('click', () => {
    src.value = PRESETS[b.dataset.preset];
    paint();
    root.querySelectorAll('[data-preset]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
    schedule(0); share();
  }));
  src.addEventListener('input', () => {
    paint();
    root.querySelectorAll('[data-preset]').forEach((x) => x.setAttribute('aria-pressed', 'false'));
    schedule(150); share();
  });

  const hash = new URLSearchParams(location.hash.slice(1));
  let initial = PRESETS.ci;
  try { if (hash.get('try')) initial = dec(hash.get('try')); } catch {}
  src.value = initial;
  if (initial === PRESETS.ci) root.querySelector('[data-preset="ci"]').setAttribute('aria-pressed', 'true');
  paint();
  setSize(SIZES.includes(size) ? size : 10);
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
