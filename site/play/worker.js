// One renderer per worker, picked by ?e=: mercat, mermaid-ascii, beautiful-mermaid or termaid.
// A renderer that throws or traps reports `dead`, and the page starts a fresh worker.
const engine = new URL(self.location.href).searchParams.get('e');

async function wasm(path, imports = {}) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`could not load ${path}`);
  return (await WebAssembly.instantiate(await res.arrayBuffer(), imports)).instance;
}

const loaders = {
  async mercat() {
    const x = (await wasm('bin/mercat.wasm')).exports;
    const enc = new TextEncoder(), dec = new TextDecoder();
    const read = (ptr, len) => dec.decode(new Uint8Array(x.memory.buffer, ptr, len));
    return (src, width) => {
      const bytes = enc.encode(src), n = Math.max(bytes.length, 1);
      const ptr = x.alloc(n);
      new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
      const drawn = x.render(ptr, bytes.length, width);
      x.free(ptr, n);
      const text = read(x.output(), x.outputLen());
      const warnings = read(x.warnings(), x.warningsLen()).trim();
      return drawn ? { text, warnings } : { error: text ? `Parse error: ${text}` : 'mercat could not draw this diagram.', warnings };
    };
  },
  async 'mermaid-ascii'() {
    await import('./bin/wasm_exec.js');
    const go = new self.Go();
    go.run(await wasm('bin/mermaid-ascii.wasm', go.importObject));
    await Promise.resolve();
    return (src, width) => {
      const r = self.mermaidAscii(src, width);
      return r.error ? { error: r.error } : { text: r.text };
    };
  },
  async 'beautiful-mermaid'() {
    const m = await import('https://cdn.jsdelivr.net/npm/beautiful-mermaid@1.1.3/+esm');
    return (src) => ({ text: m.renderMermaidASCII(src, { colorMode: 'none' }) });
  },
  // termaid is pure Python: Pyodide runs it, and its CLI's own --width fit does the fitting
  async termaid() {
    const { loadPyodide } = await import('https://cdn.jsdelivr.net/pyodide/v0.28.3/full/pyodide.mjs');
    const py = await loadPyodide();
    await py.loadPackage('micropip');
    await py.pyimport('micropip').install('termaid==0.9.1');
    const fit = py.runPython(`
import argparse
from termaid import render, cli
args = argparse.Namespace(show_ids=False, ascii=False, padding_x=4, padding_y=2, sharp_edges=False,
                          gap=4, inline_edge_labels=False, no_auto_fit=False)
lambda src, width: cli._render_one(src, args, render, target_width=width)
`);
    return (src, width) => {
      try { return { text: fit(src, width) }; } catch (e) {
        return { error: `termaid could not draw this diagram: ${String(e.message).trim().split('\n').pop()}` };
      }
    };
  },
};

const ready = loaders[engine]();
ready.then(() => postMessage({ loaded: true }), () => {});

self.onmessage = async ({ data }) => {
  let render;
  try { render = await ready; } catch (e) {
    postMessage({ id: data.id, error: `Could not load ${engine}.`, dead: true });
    return;
  }
  try {
    const t0 = performance.now();
    const r = render(data.src, data.width);
    postMessage({ id: data.id, ms: performance.now() - t0, ...r });
  } catch (e) {
    postMessage({ id: data.id, error: `${engine} failed on this input.`, dead: true });
  }
};
