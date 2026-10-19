(() => {
  const live = document.getElementById('live');
  const mac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

  // copy buttons: both labels share one grid cell, so the button never changes size
  document.querySelectorAll('[data-copy]').forEach((b) => {
    b.textContent = '';
    [['l-copy', 'Copy'], ['l-ok', 'Copied']].forEach(([c, t]) => {
      const sp = document.createElement('span'); sp.className = c; sp.textContent = t; b.appendChild(sp);
    });
    // if the clipboard is refused, select the command so a manual copy works
    b.addEventListener('click', async () => {
      const text = b.dataset.copy;
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch {
        const t = document.createElement('textarea'); t.value = text; t.setAttribute('readonly', ''); t.style.position = 'fixed'; t.style.opacity = '0';
        document.body.appendChild(t); t.select(); try { ok = document.execCommand('copy'); } catch {} t.remove();
      }
      if (!ok) {
        const code = b.parentElement.querySelector('code');
        if (code) { const r = document.createRange(); r.selectNodeContents(code); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
      }
      b.dataset.state = ok ? 'ok' : 'no';
      if (live) live.textContent = ok ? 'Copied to the clipboard' : `Copy failed. The command is selected: press ${mac ? 'Cmd+C' : 'Ctrl+C'}.`;
      clearTimeout(b._t); b._t = setTimeout(() => { delete b.dataset.state; }, ok ? 1600 : 4000);
    });
  });

  // tabs: one per chart type, each linkable by its #hash
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  if (tabs.length) {
    const panels = tabs.map((t) => document.getElementById(t.getAttribute('aria-controls')));
    const show = (i, { focus = false, hash = false } = {}) => {
      tabs.forEach((t, k) => { t.setAttribute('aria-selected', String(k === i)); t.tabIndex = k === i ? 0 : -1; });
      panels.forEach((p, k) => p.classList.toggle('is-on', k === i));
      if (focus) tabs[i].focus();
      if (hash) history.replaceState(null, '', '#' + tabs[i].dataset.hash);
      stops();
    };
    const fromHash = () => {
      const i = tabs.findIndex((t) => '#' + t.dataset.hash === location.hash);
      if (i >= 0) { show(i); return true; }
      return false;
    };
    tabs.forEach((t, i) => {
      t.addEventListener('click', () => show(i, { hash: true }));
      t.addEventListener('keydown', (e) => {
        const n = tabs.length;
        const to = { ArrowRight: (i + 1) % n, ArrowLeft: (i - 1 + n) % n, Home: 0, End: n - 1 }[e.key];
        if (to === undefined) return;
        e.preventDefault(); show(to, { focus: true, hash: true });
      });
    });
    addEventListener('hashchange', () => {
      if (fromHash()) document.querySelector('.tabbar').scrollIntoView({ block: 'start' });
    });
    if (!fromHash()) show(0);
    else requestAnimationFrame(() => document.querySelector('.tabbar').scrollIntoView({ block: 'start' }));
  }

  // a scrolling block is a tab stop only while it really scrolls; a cut-off drawing fades at its edge
  function stops() {
    document.querySelectorAll('.card-src, .card-draw').forEach((p) => {
      const scrolls = p.scrollWidth > p.clientWidth + 1;
      p.tabIndex = scrolls ? 0 : -1;
      if (p.classList.contains('card-draw')) p.toggleAttribute('data-more', p.scrollLeft + p.clientWidth < p.scrollWidth - 1);
    });
  }
  document.querySelectorAll('.card-draw').forEach((p) => p.addEventListener('scroll', () => p.toggleAttribute('data-more', p.scrollLeft + p.clientWidth < p.scrollWidth - 1), { passive: true }));
  stops(); addEventListener('resize', stops);
  document.fonts && document.fonts.ready.then(stops);
})();
