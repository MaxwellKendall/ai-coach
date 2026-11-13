// FIT-458: every screen the iPhone app can show, read from the Swift, and the review demo's coverage of them.
// A screen is a tab, a view presented by .sheet / .fullScreenCover / .popover / .navigationDestination / NavigationLink,
// or a state inside a view (a ContentUnavailableView, an .alert). Roles come from the tab bar: Clients is the coach's,
// Today, Program and Progress are a lifter's (solo or a coach's client), and what RootView presents is everyone's.
// The rules are static and approximate; appstore/review/coverage-exclude.txt holds the reasoned exceptions.

export const ROLES = ["solo", "client", "coach"];

// RootView's tabs, by the title passed to Tab(…). Tabs behind a pilot flag are listed so nothing they reach is required.
export const TABS = {
  Clients: { roles: ["coach"] },
  Today: { roles: ["solo", "client"] },
  Program: { roles: ["solo", "client"] },
  Progress: { roles: ["solo", "client"] },
  "groupsTab.title": { roles: [], hidden: "Groups are off while Pilot.simple (Pilot.groups)" },
  Coach: { roles: [], hidden: "The in-app coach is off while Pilot.simple (LanguageModel.isAvailable needs Pilot.inAppAI)" },
};

// Views with a variant per argument: each variant is its own screen, reachable only by the roles listed.
// FIT-437 (AppMode.offers): Lifter Pro's paywall is a solo lifter's, Coach Pro's a coach's.
export const VARIANTS = {
  PaywallView: { lifter: ["solo"], coach: ["coach"] },
};

const PRESENTERS = [
  { re: /\.sheet\s*\(/g, kind: "sheet" },
  { re: /\.fullScreenCover\s*\(/g, kind: "cover" },
  { re: /\.popover\s*\(/g, kind: "sheet" },
  { re: /\.navigationDestination\s*\(/g, kind: "push" },
  { re: /\bNavigationLink\s*[({]/g, kind: "push" },
];

/** Blanks comments and string contents (keeping offsets), so braces and names inside them are not code. */
export function mask(source) {
  const out = source.split("");
  let i = 0;
  const blank = (from, to) => { for (let k = from; k < to; k++) if (out[k] !== "\n") out[k] = " "; };
  while (i < source.length) {
    if (source.startsWith("//", i)) {
      const end = source.indexOf("\n", i);
      const stop = end < 0 ? source.length : end;
      blank(i, stop); i = stop;
    } else if (source.startsWith("/*", i)) {
      const end = source.indexOf("*/", i + 2);
      const stop = end < 0 ? source.length : end + 2;
      blank(i, stop); i = stop;
    } else if (source.startsWith('"""', i)) {
      const end = source.indexOf('"""', i + 3);
      const stop = end < 0 ? source.length : end + 3;
      blank(i + 3, stop - 3); i = stop;
    } else if (source[i] === '"') {
      let k = i + 1;
      while (k < source.length && source[k] !== '"' && source[k] !== "\n") {
        if (source[k] === "\\") {
          // \( … ) interpolation: skip to its closing paren, counting nested parens.
          if (source[k + 1] === "(") {
            let depth = 0; k += 1;
            do { if (source[k] === "(") depth++; else if (source[k] === ")") depth--; k++; } while (depth > 0 && k < source.length);
            continue;
          }
          k += 2; continue;
        }
        k++;
      }
      blank(i + 1, k); i = k + 1;
    } else i++;
  }
  return out.join("");
}

/** Index of the bracket closing the one at `open` in masked source, or -1. */
export function closing(masked, open) {
  const pairs = { "(": ")", "{": "}", "[": "]" };
  const want = pairs[masked[open]];
  let depth = 0;
  for (let k = open; k < masked.length; k++) {
    const c = masked[k];
    if (c === masked[open]) depth++;
    else if (c === want && --depth === 0) return k;
  }
  return -1;
}

const slug = (text) => text.toLowerCase().replace(/[’']/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48);
const literal = (source, at) => { const m = /^\s*"((?:[^"\\]|\\.)*)"/.exec(source.slice(at)); return m ? m[1] : null; };

/**
 * files: [{ path, source }]. Returns the inventory: { screens: [...] }, sorted by id, with no timestamps, so a rerun
 * on the same sources gives the same file.
 */
export function inventory(files) {
  // 1. Every `struct X: … View` and its body, innermost-first ownership.
  const views = new Map();
  const blocks = [];
  for (const file of files) {
    const masked = mask(file.source);
    file.masked = masked;
    const re = /\bstruct\s+(\w+)\s*(?:<[^>{]*>)?\s*:\s*([^{]*)\{/g;
    for (let m; (m = re.exec(masked));) {
      if (!/\bView\b/.test(m[2])) continue;
      const open = m.index + m[0].length - 1;
      const close = closing(masked, open);
      const block = { name: m[1], file, start: open, end: close < 0 ? masked.length : close };
      views.set(m[1], block);
      blocks.push(block);
    }
  }
  const owner = (file, at) => {
    let best = null;
    for (const b of blocks) if (b.file === file && b.start <= at && at <= b.end && (!best || b.start > best.start)) best = b;
    return best;
  };
  const names = [...views.keys()].sort((a, b) => b.length - a.length);
  const nameRe = new RegExp(`\\b(${names.join("|")})\\s*(?=[({])`, "g");

  // Views a region names, with a variant when the call passes a literal `plan: .x` (VARIANTS).
  const named = (file, from, to) => {
    const found = [];
    const text = file.masked.slice(from, to);
    nameRe.lastIndex = 0;
    for (let m; (m = nameRe.exec(text));) {
      const at = from + m.index;
      const after = file.masked.slice(at + m[1].length, at + m[1].length + 120);
      let variant;
      if (VARIANTS[m[1]]) {
        const v = /^\s*\(\s*\w+\s*:\s*\.(\w+)/.exec(after);
        variant = v && VARIANTS[m[1]][v[1]] ? v[1] : "*";
      }
      found.push({ name: m[1], variant, at });
    }
    return found;
  };

  // 2. Edges between views: presented (sheet, cover, push, tab) or contained (the rest of the body).
  const edges = [];
  const presentedSpans = [];
  const roots = [];
  const states = [];
  for (const file of files) {
    const m = file.masked;
    const spanEdges = (kind, from, to, at, extra = {}) => {
      presentedSpans.push({ file, from, to });
      const by = owner(file, at);
      for (const target of named(file, from, to)) edges.push({ from: by?.name ?? null, to: target, kind, file: file.path, ...extra });
    };
    for (const { re, kind } of PRESENTERS) {
      re.lastIndex = 0;
      for (let p; (p = re.exec(m));) {
        const open = p.index + p[0].length - 1;
        const link = p[0].startsWith("NavigationLink");
        let from, to;
        if (m[open] === "{") {
          // `NavigationLink { Destination() } label: { … }`: the first closure is the screen.
          from = open; to = closing(m, open);
        } else {
          const argsEnd = closing(m, open);
          if (argsEnd < 0) continue;
          const args = m.slice(open, argsEnd + 1);
          if (link) {
            // `NavigationLink(value:)` is pushed by a .navigationDestination elsewhere; `(destination: X())` names it here.
            if (/\bvalue\s*:/.test(args)) continue;
            from = open; to = argsEnd;
          } else {
            const trailing = /^\s*\{/.exec(m.slice(argsEnd + 1));
            if (trailing) { from = argsEnd + trailing[0].length; to = closing(m, from); }
            // `content: sheetView`, `destination: session`: a function in the same view builds the screen.
            const fn = /(?:content|destination)\s*:\s*(\w+)\s*[,)]/.exec(args);
            if (fn && !views.has(fn[1])) {
              const by = owner(file, p.index);
              const base = by?.start ?? 0;
              const def = new RegExp(`func\\s+${fn[1]}\\s*\\(`).exec(m.slice(base, by?.end ?? m.length));
              if (def) {
                const body = m.indexOf("{", base + def.index + def[0].length);
                spanEdges(kind, body, closing(m, body), p.index);
              }
            }
          }
        }
        if (to > from) spanEdges(kind, from, to, p.index);
      }
    }
    // Tabs: `Tab("Today", …) { TodayScreen() }`, `Tab(groupsTab.title, …) { … }`.
    const tabRe = /\bTab\s*\(/g;
    for (let t; (t = tabRe.exec(m));) {
      const open = t.index + t[0].length - 1;
      const argsEnd = closing(m, open);
      const title = literal(file.source, open + 1) ?? m.slice(open + 1, argsEnd).split(",")[0].trim();
      const brace = /^\s*\{/.exec(m.slice(argsEnd + 1));
      if (!brace || !TABS[title]) continue;
      const from = argsEnd + brace[0].length, to = closing(m, from);
      presentedSpans.push({ file, from, to });
      const target = named(file, from, to).find((n) => n.name !== "NavigationStack");
      if (target) roots.push({ tab: title, ...TABS[title], to: target, file: file.path });
    }
    // States: empty and error views inside a screen, and alerts.
    for (const re of [/\bContentUnavailableView\s*[({]/g, /\.alert\s*\(/g]) {
      for (let s; (s = re.exec(m));) {
        const by = owner(file, s.index);
        if (!by) continue;
        const open = s.index + s[0].length - 1;
        let title = m[open] === "(" ? literal(file.source, open + 1) : null;
        if (!title && m[open] === "(") {
          // ContentUnavailableView(coached ? "A" : "B", …) or a computed title: name it by its first literal.
          const args = file.source.slice(open + 1, closing(m, open));
          const first = /"((?:[^"\\]|\\.)*)"/.exec(args.split("systemImage")[0]);
          title = first ? first[1] : null;
        }
        if (!title && m[open] === "{") {
          const inner = file.source.slice(open, closing(m, open));
          const label = /Label\s*\(\s*"((?:[^"\\]|\\.)*)"/.exec(inner) ?? /Text\s*\(\s*"((?:[^"\\]|\\.)*)"/.exec(inner);
          title = label ? label[1] : null;
        }
        const kind = re.source.includes("alert") ? "alert" : "empty";
        title = (title ?? kind).replace(/\\\(.*?\)/g, "…");
        states.push({ view: by.name, kind, title, file: file.path });
      }
    }
  }
  const inSpan = (file, at) => presentedSpans.some((s) => s.file === file && s.from <= at && at <= s.to);
  for (const b of blocks) {
    for (const target of named(b.file, b.start, b.end)) {
      if (target.name === b.name || inSpan(b.file, target.at)) continue;
      const inner = owner(b.file, target.at);
      if (inner !== b) continue;
      edges.push({ from: b.name, to: target, kind: "contains", file: b.file.path });
    }
  }
  const rootView = files.find((f) => views.has("RootView") && views.get("RootView").file === f);

  // 3. Screens, then roles flowing from the roots: RootView is everyone's, each tab its own roles.
  const key = (n) => (n.variant && n.variant !== "*" ? `${n.name}.${n.variant}` : n.name);
  const screens = new Map();
  const addScreen = (id, fields) => {
    const s = screens.get(id) ?? { id, node: fields.node ?? id, title: fields.title, kind: fields.kind, view: fields.view, file: fields.file, from: new Set() };
    if (fields.from) s.from.add(fields.from);
    screens.set(id, s);
    return s;
  };
  const viewTitle = (name) => {
    const b = views.get(name);
    if (!b) return name;
    const t = /\.navigationTitle\s*\(\s*"((?:[^"\\]|\\.)*)"/.exec(b.file.source.slice(b.start, b.end));
    return t ? t[1] : name.replace(/(View|Screen|Sheet)$/, "").replace(/([a-z])([A-Z])/g, "$1 $2") || name;
  };
  const variantsOf = (n) => (n.variant === "*" ? Object.keys(VARIANTS[n.name]).map((v) => ({ ...n, variant: v })) : [n]);
  for (const e of edges) {
    if (e.kind === "contains") continue;
    for (const n of variantsOf(e.to)) addScreen(key(n), { title: viewTitle(n.name), kind: e.kind, view: n.name, file: views.get(n.name).file.path, from: e.from });
  }
  // A tab is its own screen even when two tabs share a view (Program and Progress are both ProgramScreen).
  const tabName = (r) => (r.tab === "groupsTab.title" ? "Groups" : r.tab);
  for (const r of roots) addScreen(`tab.${tabName(r)}`, { node: key(r.to), title: tabName(r), kind: "tab", view: r.to.name, file: views.get(r.to.name).file.path, from: "RootView" });
  for (const s of states) addScreen(`${s.view}.${s.kind}.${slug(s.title)}`, { node: s.view, title: s.title, kind: s.kind, view: s.view, file: s.file, from: s.view });

  // Roles per view node (and per variant node), by breadth-first search with the path that first reached it.
  const roles = new Map();
  const paths = new Map();
  const queue = [];
  const reach = (node, rs, path) => {
    const had = roles.get(node) ?? new Set();
    const add = rs.filter((r) => !had.has(r));
    if (!add.length && roles.has(node)) return;
    add.forEach((r) => had.add(r));
    roles.set(node, had);
    if (!paths.has(node) || (paths.get(node).length > path.length && add.length)) paths.set(node, path);
    queue.push([node, add.length ? add : rs, path]);
  };
  if (rootView) reach("RootView", [...ROLES], ["RootView"]);
  for (const r of roots) reach(key(r.to), r.roles, ["RootView", `tab.${tabName(r)}`]);
  const byFrom = new Map();
  for (const e of edges) {
    if (!e.from) continue;
    for (const n of variantsOf(e.to)) {
      const list = byFrom.get(e.from) ?? [];
      list.push({ to: key(n), name: n.name, variant: n.variant, kind: e.kind });
      byFrom.set(e.from, list);
    }
  }
  while (queue.length) {
    const [node, rs, path] = queue.shift();
    const view = node.split(".")[0];
    for (const e of byFrom.get(view) ?? []) {
      let next = rs;
      if (e.variant && VARIANTS[e.name]?.[e.variant]) next = rs.filter((r) => VARIANTS[e.name][e.variant].includes(r));
      if (!next.length) continue;
      reach(e.to, next, e.kind === "contains" ? path : [...path, e.to]);
    }
  }
  const hiddenBy = new Map();
  for (const r of roots) if (r.hidden) hiddenBy.set(key(r.to), r.hidden);

  const list = [...screens.values()].map((s) => {
    const node = s.node;
    const rs = ROLES.filter((r) => roles.get(node)?.has(r));
    const entry = { id: s.id, title: s.title, kind: s.kind, file: s.file, roles: rs, from: [...s.from].sort() };
    const path = paths.get(node);
    if (s.kind === "tab") entry.path = ["RootView", s.id];
    else if (path) entry.path = path.at(-1) === s.id ? path : [...path, s.id];
    if (!rs.length) entry.unreachable = hiddenBy.get(node) ?? "No route from RootView or a visible tab was found";
    return entry;
  });
  list.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { screens: list };
}

/** `id  # reason` lines; blank lines and lines starting with # are comments. */
export function parseExcludes(text) {
  const out = new Map();
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const [id, ...reason] = t.split("#");
    out.set(id.trim(), reason.join("#").trim());
  }
  return out;
}

/** `role id` lines, written by the review demo's UI test as it shows each screen. */
export function parseMarks(text) {
  const out = [];
  for (const line of text.split("\n")) {
    const [role, id] = line.trim().split(/\s+/);
    if (role && id) out.push({ role, id });
  }
  return out;
}

/**
 * Every screen a visible role can reach must be shown at least once by a chapter of one of those roles, or be
 * excluded with a reason. Marks of ids that aren't in the inventory are reported too, since they can't count.
 */
export function coverage({ screens }, marks, excludes = new Map()) {
  const byId = new Map(screens.map((s) => [s.id, s]));
  const shown = new Map();
  const unknown = [];
  for (const { role, id } of marks) {
    const s = byId.get(id);
    if (!s || !ROLES.includes(role)) { unknown.push(`${role} ${id}`); continue; }
    if (s.roles.includes(role)) shown.set(id, (shown.get(id) ?? new Set()).add(role));
  }
  // Grouped by who can reach the screen ("solo, client"), so a chapter of any of them can show it.
  const missing = {};
  let required = 0;
  for (const s of screens) {
    if (!s.roles.length || excludes.has(s.id)) continue;
    required++;
    if (shown.has(s.id)) continue;
    (missing[s.roles.join(", ")] ??= []).push(s.id);
  }
  const staleExcludes = [...excludes.keys()].filter((id) => !byId.has(id));
  const missed = Object.values(missing).flat().length;
  return { required, shown: required - missed, missing, unknown, staleExcludes, ok: missed === 0 && unknown.length === 0 };
}

export function report(result) {
  const lines = [`Review demo coverage: ${result.shown} of ${result.required} screens shown.`];
  for (const [roles, ids] of Object.entries(result.missing).sort()) {
    lines.push(`Not shown, reachable by ${roles}: ${ids.length}`);
    for (const id of ids) lines.push(`  ${id}`);
  }
  if (result.unknown.length) lines.push(`Marked but not in the inventory: ${result.unknown.join(", ")}`);
  if (result.staleExcludes.length) lines.push(`Excluded but not in the inventory: ${result.staleExcludes.join(", ")}`);
  return lines.join("\n");
}
