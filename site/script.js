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

  // the film: one play button over the poster; the mp4 loads only once asked for
  const film = document.querySelector('.film-screen');
  if (film) {
    const v = film.querySelector('video'), b = film.querySelector('.film-play');
    v.controls = false; b.hidden = false;
    v.addEventListener('play', () => { b.hidden = true; v.controls = true; });
    b.addEventListener('click', () => { v.controls = true; b.hidden = true; v.focus(); v.play().catch(() => {}); });
  }
})();
