// Runs the design mock's own logic (design/project/Main.dc.html) through its
// controls and reports any state that throws, shows NaN/undefined/Infinity, or
// leaves a template hole unfilled. Prints one JSON line: {"states":n,"problems":k,...}
//   node tests/design_sweep.js design/project/Main.dc.html
const fs = require('fs');
const STEP = process.argv.includes('--full') ? 3 : 40;
const html = fs.readFileSync(process.argv[2], 'utf8');
const js = html.match(/<script type="text\/x-dc" data-dc-script[^>]*>([\s\S]*?)<\/script>/)[1];
class DCLogic { constructor(p) { this.props = p || {}; this.state = {}; } setState(o) { Object.assign(this.state, o); } }
const Component = new Function('DCLogic', js + '\nreturn Component;')(DCLogic);

const bad = [];
const walk = (o, path) => {
  if (o === undefined || (typeof o === 'number' && !isFinite(o))) bad.push(path);
  else if (typeof o === 'string' && /NaN|undefined|Infinity/.test(o)) bad.push(path + '=' + o);
  else if (o && typeof o === 'object') for (const k in o) walk(o[k], path + '.' + k);
};
const c = new Component({ startPage: 'cases' });
if (c.state.page !== 'cases') bad.push('startPage');

let n = 0, i = 0, worst = 0;
outer:
for (const page of ['portfolio', 'cases', 'data', 'defs'])
for (const mi of [0, 1, 4, 8])
for (const bench of ['sf', 'af', 'uf'])
for (const rec of ['all', 'yes', 'no'])
for (const pWin of ['m', 'l1', 'l3', 'l6', 'l12'])
for (const cWin of ['m', 'l1', 'l3', 'l6', 'l12'])
for (const ppGrain of ['Country', 'Servicer', 'Seller', 'Deal', 'bogus'])
for (const cpSort of ['cc', 'ce', 'new', 'lost', 'net', 'first', 'three', 'ever', 'name', 'bogus']) {
  if ((i++) % STEP) continue;   // deterministic sample: 1 in 100 by default (~10s), every 7th with --full
  Object.assign(c.state, { page, mi, bench, rec, pWin, cWin, ppGrain, cpSort, cpSortDir: [1, -1, 0][i % 3], view: ['monthly', 'cumulative'][i % 2],
    pCmp: ['sf', 'af', 'uf', 'prior'][i % 4], cKm: ['paying', 'first', 'steady', 'lost'][i % 4],
    beh: ['flow', 'paying', 'first', 'steady', 'bogus'][i % 5], pHover: [null, 0, 8][i % 3], cHover: [null, 8, 0][i % 3],
    dPage: ['all', 'Portfolio', 'Cases'][i % 3], dWin: ['m', 'l1', 'l3', 'l6', 'l12', 'bogus'][i % 6], dq: ['', 'jitter', 'L3M', 'zzz-no-match', '€ (%)', 'RECONCILED'][i % 6],
    ppWin: ['l3', 'm', 'l1', 'l6', 'l12', 'bogus'][i % 6], cpWin: ['m', 'l12', 'l3', 'l1', 'l6'][i % 5], ppSort: ['coll', 'pct', 'gap', 'net', 'cost', 'name', 'x'][i % 7], ppSortDir: [-1, 1, 7][i % 3],
    cpGrain: ['Deal', 'Country', 'Seller', 'Servicer'][i % 4],
    cMeasure: ['count', 'eur', 'avg', 'bogus'][Math.floor(i / 2) % 4], cBar: [null, '0:0', '8:4', '3:2', '8:5', '99:9', 'x'][i % 7], ppBench: ['sf', 'af', 'uf', 'bogus'][i % 4], cSel: [[], ['Fresh'], ['New', 'Lost'], 'bogus', ['All Collected Cases'], null][i % 6],
    pfCol: i % 16, pfDir: [1, -1][i % 2], cfCol: (i * 3) % 18, cfDir: [-1, 1][i % 2],
    pSpH: [null, 0, 3, 8, 20][i % 5], cSpH: [8, null, 0][i % 3] });
  const t0 = Date.now();
  try { walk(c.renderVals(), 'state#' + i); } catch (e) { bad.push('state#' + i + ' threw ' + e.message); }
  worst = Math.max(worst, Date.now() - t0); n++;
  if (bad.length > 20) break outer;
}
// handlers reject bad input and accept good input
const v = c.renderVals();
v.pickMonth({ target: { value: 'x' } }); v.pickMonth({ target: { value: '3' } });
v.c.pickKm({ target: { value: 'nope' } }); v.clearFilters(); v.pickMonth({ target: { value: '3' } }); v.p.chart.zones[0].enter(); v.p.leave();
v.p.perf.grainOpts[2].pick(); v.p.perf.cols.forEach((_, k) => c.renderVals().p.perf.cols[k].sort());   // fresh render each click: a click on the sorted column only flips direction v.p.full.cols[7].sort(); v.p.full.cols[7].sort(); v.c.full.cols[0].sort();
v.c.view.cols[0].segs[0].enter(); v.c.vleave(); v.c.view.cols.at(-1).segs.at(-1).enter();
const lg = (name) => c.renderVals().c.legend.find((l) => l.label === name);
Object.assign(c.state, { cSel: [] }); lg('Fresh').pick(); lg('New').pick(); if (c.state.cSel.join() !== 'Fresh,New') bad.push('legend did not select two behaviours'); lg('Fresh').pick(); c.renderVals().c.legendClear();
v.p.spark.zones[0].enter(); v.p.spark.leave(); v.c.spark.zones[0].enter(); v.c.spark.leave();
for (const h of v.p.full.cols) h.sort(); for (const h of v.c.full.cols) h.sort(); v.c.perf.grainOpts.forEach((o) => o.pick()); v.c.perf.cols.forEach((_, k) => c.renderVals().c.perf.cols[k].sort()); v.p.perf.winOpts[3].pick(); v.p.perf.benchOpts[1].pick(); if (c.state.ppBench !== 'af') bad.push('§2 benchmark did not switch'); v.c.perf.winOpts[2].pick();
walk(c.renderVals(), 'after-handlers');
// The last header clicked on each Performance table is its sort column.
Object.assign(c.state, { ppSort: 'x', cpSort: 'x' }); c.renderVals().p.perf.cols.at(-1).sort(); c.renderVals().c.perf.cols.at(-1).sort();
if (c.state.mi !== 3 || c.state.ppSort !== 'cost_vs' || c.state.cpSort !== 'net_vs') bad.push('handlers did not apply valid input');
// every metric label a viewer can see has a data definition (docs/definitions.csv)
const vDefs = c.renderVals();
const defNames = new Set();
const DEFS = vDefs.dd ? null : null;
const defsSrc = html.match(/\n    const DEFS = (\[.*?\]);\n/);
if (!defsSrc) bad.push('no DEFS array in the design - run docs/build_definitions.py');
else for (const d of JSON.parse(defsSrc[1])) { defNames.add(d.term.toLowerCase()); for (const a of d.aliases.split('|')) if (a) defNames.add(a.toLowerCase()); }
const norm = (x) => x.toLowerCase().replace(/ · .*$/, '').replace(/ in [a-z]{3} \d\d$/, '').replace(/ \(€\)$/, '').replace(/ \((mom|qoq|hoh|yoy)\)$/, '').trim();
const undefinedTerms = new Set();
const need = (label) => { for (const part of String(label).split(/ vs (?=[a-z])/i)) { let k = norm(part); if (k && !defNames.has(k)) k = k.replace(/^average monthly /, ''); if (k && k !== 'group' && !defNames.has(k)) undefinedTerms.add(part); } };   // 'Average Monthly X (QoQ)' is X over a window
for (const page of ['portfolio', 'cases']) {
  Object.assign(c.state, { page });
  const v = c.renderVals();
  [...v.p.tiles, ...v.c.tiles].forEach((k) => need(k.label));
  [...v.p.perf.cols, ...v.c.perf.cols].forEach((h) => { if (h.align === 'right') need(h.label); });
  [...v.p.full.cols, ...v.c.full.cols].forEach((h) => { if (h.align === 'right') need(h.label); });
  [...v.p.winOpts, ...v.p.cmpOpts, ...v.p.benchOpts, ...v.c.behOpts, ...v.p.perf.grainOpts, ...v.c.perf.grainOpts, ...v.c.funnel, ...v.c.matrix.map((m) => ({ label: m.name }))].forEach((o) => need(o.label));
  v.c.kmOpts.forEach((o) => need(o.label));
}
for (const t of undefinedTerms) bad.push('no definition for "' + t + '"');

// every {{hole}} in the template resolves on every page
const markup = html.split('<script type="text/x-dc"')[0];
const loopVars = new Set([...markup.matchAll(/as="(\w+)"/g)].map((m) => m[1]));
for (const page of ['portfolio', 'cases', 'data', 'defs']) {
  Object.assign(c.state, { page }); const vv = c.renderVals();
  for (const m of markup.matchAll(/\{\{\s*([\w.]+)\s*\}\}/g)) {
    const p = m[1].split('.'); if (loopVars.has(p[0]) || p[0] === 'true' || p[0] === 'false') continue;
    let o = vv; for (const k of p) o = o == null ? undefined : o[k];
    if (o === undefined) bad.push(page + ' hole ' + m[1]);
  }
}
console.log(JSON.stringify({ states: n, worst_ms: worst, problems: bad.length, first: bad.slice(0, 5) }));
