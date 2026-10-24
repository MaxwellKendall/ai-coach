/**
 * FIT-105: the page behind every shared link. A shared win, recap or program, or a group invite, opens here when
 * the viewer doesn't have the app (with the app, the universal link opens it instead). Every page leads one way:
 * get the app, then join the sharer's group or start their program.
 *
 * Pure: a path and a store in, a response out. `npm run web` serves it locally from fixtures; a Lambda behind
 * CloudFront will serve it from what the app saved.
 */

export type CardStyle = "dark" | "paper";

export interface Win {
  kind: "pr" | "milestone" | "streak";
  name: string;
  /** ISO date. */
  date: string;
  metric: string;
  unit: string;
  /** The new best, the value when the milestone was crossed, or the streak in weeks. */
  value: number;
  previous?: number;
  target?: number;
  /** Milestone: 25, 50, 75 or 100. */
  percent?: number;
  /** Personal best: the best so far, oldest first. */
  trend?: number[];
  /** The sharer's choice: without it, only changes and percents appear (the app's "Show weights"). */
  showNumbers: boolean;
  style: CardStyle;
  /** The sharer's group, when they attached its invite. */
  invite?: string;
  /** The sharer's program, when they attached it. */
  program?: string;
}

export interface Recap {
  name: string;
  week: number;
  weeks: number;
  phase: string;
  sessions: { done: number; planned: number };
  lifts: { metric: string; from: number; to: number; unit: string }[];
  bests: number;
  showNumbers: boolean;
  invite?: string;
  program?: string;
}

export interface Program {
  name: string;
  by: string;
  weeks: number;
  days: number;
  equipment: string;
  goals: string[];
  phases: { phase: string; from: number; to: number; focus: string; mainLifts: string[]; mainReps: number }[];
  sampleWeek: { day: string; title: string; items: string[] }[];
  invite?: string;
}

/** FIT-113: a session someone is going to do, shared so a friend can do it with them. */
export interface Session {
  name: string;
  title: string;
  /** ISO date. */
  date: string;
  /** "6:00 AM". */
  time?: string;
  minutes?: number;
  exercises: { name: string; sets: number; reps?: number; seconds?: number; load?: number; unit?: string }[];
  invite?: string;
}

export interface Invite {
  group: string;
  by: string;
  members: string[];
  /** The group's latest wins, already worded ("Jo hit a squat best"). */
  recent: string[];
}

export interface Store {
  win(id: string): Promise<Win | undefined>;
  recap(id: string): Promise<Recap | undefined>;
  program(id: string): Promise<Program | undefined>;
  invite(code: string): Promise<Invite | undefined>;
  session(id: string): Promise<Session | undefined>;
  /** FIT-130: the coach's name on a client invite still open; null when the coach has none (FIT-227). */
  coachInvite?(code: string): Promise<{ coach: string | null } | undefined>;
  /** FIT-110: one more view of a kind of page today. */
  count?(kind: string): Promise<void>;
}

export interface Site {
  appName: string;
  /** "https://repandrecipe.com", for link previews. */
  origin: string;
  /** FIT-244: the site's main address (barbrabell.com, where origin is share.barbrabell.com): the one search engines are pointed at. */
  home?: string;
  /** Until the app is on the App Store, the buttons lead to the waitlist anchor instead. */
  appStoreUrl?: string;
  /** Team ID and bundle ID, for Apple's app-site-association file. */
  appId: string;
  /** FIT-152: the MCP server's address, for /claude. */
  mcpUrl?: string;
  /** FIT-237: ChatGPT's domain-verification token for the MCP server's host. */
  openaiAppsChallenge?: string;
  /** FIT-243: the MCP Registry's domain record, "v=MCPv1; k=ed25519; p=…". */
  mcpRegistryAuth?: string;
}

export interface Page {
  status: number;
  type: string;
  body: string;
  /** FIT-122: a redirect's target (to Stripe Checkout, or from the thanks page to the gift). */
  location?: string;
  /** Pages that change as they're used (a gift's) aren't kept by CloudFront. */
  noStore?: boolean;
}

// MARK: Reading what users saved. Every field is checked and coerced, so a stored payload can only ever render
// as text and numbers (names and labels are escaped again when rendered).

class Invalid extends Error {}
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const num = (v: unknown, min = -1e6, max = 1e6) => {
  const n = typeof v === "number" ? v : Number.NaN;
  if (!Number.isFinite(n) || n < min || n > max) throw new Invalid();
  return n;
};
const optNum = (v: unknown, min?: number, max?: number) => (v === undefined || v === null ? undefined : num(v, min, max));
const str = (v: unknown, max = 80) => {
  if (typeof v !== "string" || v.length === 0 || v.length > max) throw new Invalid();
  return v;
};
const optStr = (v: unknown, max?: number) => (v === undefined || v === null ? undefined : str(v, max));
const list = <T>(v: unknown, max: number, item: (x: unknown) => T) => {
  if (!Array.isArray(v) || v.length > max) throw new Invalid();
  return v.map(item);
};
const code = (v: unknown) => (v === undefined || v === null ? undefined : /^[A-Za-z0-9_-]{1,40}$/.test(String(v)) ? String(v) : undefined);
const isoDate = (v: unknown) => {
  const d = str(v, 30);
  if (Number.isNaN(Date.parse(d))) throw new Invalid();
  return d;
};

/** A saved win, or undefined when it doesn't hold together. `name` is the sharer's, from their profile. */
export function readWin(v: unknown, name: string): Win | undefined {
  try {
    if (!isObject(v)) return undefined;
    const kind = v.kind === "pr" || v.kind === "milestone" || v.kind === "streak" ? v.kind : undefined;
    if (!kind) return undefined;
    return {
      kind, name, date: isoDate(v.date), metric: str(v.metric), unit: str(v.unit, 12), value: num(v.value),
      previous: optNum(v.previous), target: optNum(v.target), percent: optNum(v.percent, 0, 100),
      trend: v.trend === undefined ? undefined : list(v.trend, 60, (x) => num(x)),
      showNumbers: v.showNumbers === true, style: v.style === "paper" ? "paper" : "dark",
      invite: code(v.invite), program: code(v.program),
    };
  } catch (e) {
    if (e instanceof Invalid) return undefined;
    throw e;
  }
}

export function readRecap(v: unknown, name: string): Recap | undefined {
  try {
    if (!isObject(v) || !isObject(v.sessions)) return undefined;
    return {
      name, week: num(v.week, 1, 104), weeks: num(v.weeks, 1, 104), phase: str(v.phase, 20),
      sessions: { done: num(v.sessions.done, 0, 999), planned: num(v.sessions.planned, 0, 999) },
      lifts: list(v.lifts, 8, (l) => {
        if (!isObject(l)) throw new Invalid();
        return { metric: str(l.metric), from: num(l.from, 0.1), to: num(l.to), unit: str(l.unit, 12) };
      }),
      bests: num(v.bests, 0, 999), showNumbers: v.showNumbers === true, invite: code(v.invite), program: code(v.program),
    };
  } catch (e) {
    if (e instanceof Invalid) return undefined;
    throw e;
  }
}

export function readProgram(v: unknown, by: string): Program | undefined {
  try {
    if (!isObject(v)) return undefined;
    return {
      name: str(v.name), by, weeks: num(v.weeks, 1, 104), days: num(v.days, 1, 7), equipment: str(v.equipment, 40),
      goals: list(v.goals, 6, (g) => str(g)),
      phases: list(v.phases, 8, (p) => {
        if (!isObject(p)) throw new Invalid();
        return {
          phase: str(p.phase, 20), from: num(p.from, 1, 104), to: num(p.to, 1, 104), focus: str(p.focus, 240),
          mainLifts: list(p.mainLifts, 6, (l) => str(l)), mainReps: num(p.mainReps, 1, 50),
        };
      }),
      sampleWeek: list(v.sampleWeek, 7, (d) => {
        if (!isObject(d)) throw new Invalid();
        return { day: str(d.day, 12), title: str(d.title), items: list(d.items, 12, (i) => str(i)) };
      }),
      invite: code(v.invite),
    };
  } catch (e) {
    if (e instanceof Invalid) return undefined;
    throw e;
  }
}

export function readSession(v: unknown, name: string): Session | undefined {
  try {
    if (!isObject(v)) return undefined;
    return {
      name, title: str(v.title, 40), date: isoDate(v.date), time: optStr(v.time, 12), minutes: optNum(v.minutes, 1, 300),
      exercises: list(v.exercises, 16, (e) => {
        if (!isObject(e)) throw new Invalid();
        return {
          name: str(e.name, 60), sets: num(e.sets, 1, 20), reps: optNum(e.reps, 1, 100), seconds: optNum(e.seconds, 1, 3600),
          load: optNum(e.load, 0, 2000), unit: optStr(e.unit, 12),
        };
      }),
      invite: code(v.invite),
    };
  } catch (e) {
    if (e instanceof Invalid) return undefined;
    throw e;
  }
}

/**
 * The paths the app opens itself when it's installed: invites, as /join/CODE or join.{domain}/CODE (codes are
 * always 8 characters), shared sessions and programs, and gifts (FIT-122). Wins, recaps and programs open this page until the app can show them, so a friend who
 * already has the app still sees what was shared.
 */
export const appPaths = ["/join/*", "/????????", "/s/*", "/p/*", "/g/*", "/c/*"];

/** FIT-110: the kinds of page whose views are counted, as their paths start. */
export const viewKinds = ["w", "r", "p", "s", "join"];

export async function route(path: string, store: Store, site: Site): Promise<Page> {
  // FIT-110: a page's view, sent by its script once it's open in a browser (link-preview bots run no scripts).
  const view = /^\/v\/([a-z]+)$/.exec(path)?.[1];
  if (view !== undefined) {
    if (!viewKinds.includes(view)) return { status: 404, type: "text/plain", body: "" };
    await store.count?.(view);
    return { status: 204, type: "text/plain", body: "" };
  }
  if (path === "/.well-known/openai-apps-challenge" && site.openaiAppsChallenge) {
    return { status: 200, type: "text/plain; charset=utf-8", body: site.openaiAppsChallenge };
  }
  if (path === "/.well-known/mcp-registry-auth" && site.mcpRegistryAuth) {
    return { status: 200, type: "text/plain; charset=utf-8", body: site.mcpRegistryAuth };
  }
  if (path === "/.well-known/apple-app-site-association") {
    return { status: 200, type: "application/json", body: JSON.stringify(associationFile(site)) };
  }
  const [, kind, id = ""] = path.split("/");
  const valid = /^[A-Za-z0-9_-]{1,40}$/.test(id);
  // FIT-107: the card the app uploaded with the share, for link previews.
  const card = `${site.origin}/cards/${id}.png`;
  if (kind === "w" && valid) {
    const win = await store.win(id);
    if (win) return html(winPage(win, path, site, card));
  }
  if (kind === "r" && valid) {
    const recap = await store.recap(id);
    if (recap) return html(recapPage(recap, path, site, card));
  }
  if (kind === "s" && id.endsWith(".ics") && /^[A-Za-z0-9_-]{1,40}$/.test(id.slice(0, -4))) {
    const session = await store.session(id.slice(0, -4));
    if (session) return { status: 200, type: "text/calendar; charset=utf-8", body: calendar(session, `${site.origin}/s/${id.slice(0, -4)}`, site) };
  }
  if (kind === "s" && valid) {
    const session = await store.session(id);
    if (session) return html(sessionPage(session, id, path, site, card));
  }
  if (kind === "p" && valid) {
    const program = await store.program(id);
    if (program) return html(programPage(program, path, site, card));
  }
  if (kind === "join" && valid) {
    const invite = await store.invite(id.toUpperCase());
    if (invite) return html(invitePage(invite, id.toUpperCase(), path, site, `${site.origin}/cards/invite.png`));
  }
  if (kind === "c" && /^([A-Za-z0-9]{6}|[A-Za-z0-9]{10})$/.test(id)) {
    const invite = await store.coachInvite?.(id.toUpperCase());
    if (invite) return html(coachInvitePage(invite.coach, path, site));
  }
  if (path === "/claude" && site.mcpUrl) return html(claudePage(site, site.mcpUrl));
  if (path === "/pro/thanks" && site.mcpUrl) return { ...html(proThanksPage(site)), noStore: true };
  if (path === "/" || path === "/coaches") return html(homePage(site));
  return { ...html(missingPage(site)), status: 404 };
}

export function associationFile(site: Site) {
  return {
    applinks: { details: [{ appIDs: [site.appId], components: appPaths.map((p) => ({ "/": p })) }] },
  };
}

export const html = (body: string): Page => ({ status: 200, type: "text/html; charset=utf-8", body });

/** Everything a user typed (names, group names) goes through this. */
export const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const first = (name: string) => name.trim().split(/\s+/)[0] || name;
const date = (iso: string) => new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
const round = (n: number) => (Number.isInteger(n) ? `${n}` : n.toFixed(1));

// MARK: The win card, as the app draws it (Features/Progress/ShareCard.swift).

export function winWords(win: Win) {
  const change = win.previous ? win.value - win.previous : undefined;
  const percent = win.previous ? Math.round(((win.value - win.previous) / win.previous) * 100) : undefined;
  switch (win.kind) {
    case "pr":
      return {
        tag: "PERSONAL BEST",
        heading: win.metric,
        big: win.showNumbers ? round(win.value) : percent !== undefined ? `+${percent}` : "New",
        unit: win.showNumbers ? win.unit : percent !== undefined ? "%" : "best",
        sub: win.showNumbers && win.previous ? `Up from ${round(win.previous)} ${win.unit}` : change ? "Over the last best" : "A first best",
        title: `${first(win.name)} set a ${win.metric.toLowerCase()} best`,
      };
    case "milestone":
      return {
        tag: "GOAL",
        heading: win.metric,
        big: `${win.percent ?? 0}%`,
        unit: "of the way",
        sub: win.showNumbers && win.target ? `${round(win.value)} of ${round(win.target)} ${win.unit}` : "Toward the goal",
        title: `${first(win.name)} is ${win.percent ?? 0}% of the way to a ${win.metric.toLowerCase()} goal`,
      };
    case "streak":
      return {
        tag: "STREAK",
        heading: "Every week trained",
        big: round(win.value),
        unit: win.value === 1 ? "week" : "weeks",
        sub: "Not one planned week missed",
        title: `${first(win.name)} trained ${round(win.value)} weeks straight`,
      };
  }
}

function sparkline(values: number[]) {
  if (values.length < 2) return "";
  const min = Math.min(...values), max = Math.max(...values), span = max - min || 1;
  const points = values.map((v, i) => `${(i / (values.length - 1)) * 258},${62 - ((v - min) / span) * 54 + 4}`);
  const last = points[points.length - 1].split(",");
  return `<svg class="spark" viewBox="0 0 258 70" aria-hidden="true">
    <polyline points="${points.join(" ")}" fill="none" stroke="currentColor" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
    <circle cx="${last[0]}" cy="${last[1]}" r="5" fill="currentColor"/></svg>`;
}

function ring(percent: number) {
  const c = 2 * Math.PI * 80;
  return `<svg class="ring" viewBox="0 0 180 180" aria-hidden="true">
    <circle cx="90" cy="90" r="80" fill="none" class="track" stroke-width="11"/>
    <circle cx="90" cy="90" r="80" fill="none" stroke="currentColor" stroke-width="11" stroke-linecap="round"
      stroke-dasharray="${(c * percent) / 100} ${c}" transform="rotate(-90 90 90)"/></svg>`;
}

export function winCard(win: Win, site: Site) {
  const w = winWords(win);
  const figure =
    win.kind === "milestone"
      ? `<div class="ringwrap">${ring(win.percent ?? 0)}<div class="ringtext"><b>${esc(w.big)}</b><span>${esc(w.unit)}</span></div></div>
         <p class="sub center">${esc(w.sub)}</p>`
      : `<p class="big"><b>${esc(w.big)}</b><span>${esc(w.unit)}</span></p>
         <p class="sub">${esc(w.sub)}</p>
         <div class="grow"></div>
         ${win.kind === "pr" ? sparkline(win.trend ?? []) : `<div class="weeks">${"<i></i>".repeat(Math.min(win.value, 8))}</div>`}`;
  return `<figure class="card ${win.style}" aria-label="${esc(w.title)}">
    <p class="tag">${w.tag}</p><p class="heading">${esc(w.heading)}</p>
    ${figure}
    <footer><span>${date(win.date)}</span><span class="mark">${logo}${esc(site.appName)}</span></footer>
  </figure>`;
}

// MARK: Pages

function winPage(win: Win, path: string, site: Site, image?: string) {
  const w = winWords(win);
  const who = first(win.name);
  return layout(site, {
    view: "w",
    title: w.title,
    description: `${who} is training with ${site.appName}: a program written for their goals, and every set logged.`,
    path,
    image,
    body: `
      <section class="hero">
        ${winCard(win, site)}
        <h1>${esc(w.title)}</h1>
        <p class="lede">${esc(who)} trains with ${esc(site.appName)}: a program written around their goal, every set logged, and every best counted.</p>
        ${actions(site, [
          win.invite && { href: `/join/${encodeURIComponent(win.invite)}`, label: `Train with ${who}` },
          win.program && { href: `/p/${encodeURIComponent(win.program)}`, label: `See ${who}'s program` },
        ])}
      </section>
      ${how(site)}`,
  });
}

function recapPage(recap: Recap, path: string, site: Site, image?: string) {
  const who = first(recap.name);
  const done = recap.week >= recap.weeks;
  const title = done ? `${who} finished a ${recap.weeks}-week program` : `${who}'s week ${recap.week} of ${recap.weeks}`;
  const lift = (l: Recap["lifts"][number]) => {
    const up = l.to - l.from;
    const change = recap.showNumbers ? `${up >= 0 ? "+" : "−"}${round(Math.abs(up))} ${l.unit}` : `${up >= 0 ? "+" : "−"}${Math.round((Math.abs(up) / l.from) * 100)}%`;
    return `<li><span>${esc(l.metric)}</span><b class="${up >= 0 ? "up" : ""}">${change}</b>${recap.showNumbers ? `<small>${round(l.from)} → ${round(l.to)}</small>` : ""}</li>`;
  };
  return layout(site, {
    view: "r",
    title,
    description: `${recap.sessions.done} of ${recap.sessions.planned} sessions, ${recap.bests} new ${recap.bests === 1 ? "best" : "bests"}. Training with ${site.appName}.`,
    path,
    image,
    body: `
      <section class="hero">
        <article class="recap">
          <p class="tag">${done ? "PROGRAM DONE" : `${esc(recap.phase.toUpperCase())} PHASE`}</p>
          <p class="recap-week"><b>${done ? recap.weeks : recap.week}</b><span>${done ? "weeks, done" : `of ${recap.weeks} weeks`}</span></p>
          <div class="bar" role="img" aria-label="${recap.week} of ${recap.weeks} weeks"><i style="width:${Math.min(100, (recap.week / recap.weeks) * 100)}%"></i></div>
          <div class="tiles">
            <div><b>${recap.sessions.done}/${recap.sessions.planned}</b><span>sessions</span></div>
            <div><b>${recap.bests}</b><span>new ${recap.bests === 1 ? "best" : "bests"}</span></div>
          </div>
          <ul class="lifts">${recap.lifts.map(lift).join("")}</ul>
          <footer><span>${esc(recap.name)}</span><span class="mark">${logo}${esc(site.appName)}</span></footer>
        </article>
        <h1>${esc(title)}</h1>
        <p class="lede">Every week, ${esc(site.appName)} looks at what ${esc(who)} logged and sets the next week's weights.</p>
        ${actions(site, [
          recap.invite && { href: `/join/${encodeURIComponent(recap.invite)}`, label: `Train with ${who}` },
          recap.program && { href: `/p/${encodeURIComponent(recap.program)}`, label: `See ${who}'s program` },
        ])}
      </section>
      ${how(site)}`,
  });
}

function programPage(program: Program, path: string, site: Site, image?: string) {
  const who = first(program.by);
  return layout(site, {
    view: "p",
    title: `${program.name}, by ${who}`,
    description: `${program.weeks} weeks, ${program.days} days a week, ${program.equipment}. Start it with your own weights in ${site.appName}.`,
    path,
    image,
    body: `
      <section class="hero left">
        <p class="eyebrow">${esc(who)}'s program</p>
        <h1>${esc(program.name)}</h1>
        <div class="chips"><span>${program.weeks} weeks</span><span>${program.days} days a week</span><span>${esc(program.equipment)}</span></div>
        ${program.goals.length ? `<p class="goals">Built for ${program.goals.map((g) => `<b>${esc(g)}</b>`).join(" and ")}</p>` : ""}
        ${actions(site, [program.invite && { href: `/join/${encodeURIComponent(program.invite)}`, label: `Train alongside ${who}` }], "Start this program")}
        <p class="fine">Your weights come from your own numbers, not ${esc(who)}'s.</p>
      </section>
      <section class="block">
        <h2>The plan</h2>
        <ol class="phases">${program.phases
          .map(
            (p) => `<li><div class="weeks-label">Weeks ${p.from}${p.to > p.from ? `–${p.to}` : ""}</div>
              <h3>${esc(p.phase[0].toUpperCase() + p.phase.slice(1))}</h3><p>${esc(p.focus)}</p>
              <p class="lifts-line">${p.mainLifts.map(esc).join(" · ")} <span>× ${p.mainReps}</span></p></li>`,
          )
          .join("")}</ol>
      </section>
      <section class="block">
        <h2>A week of it</h2>
        <div class="days">${program.sampleWeek
          .map((d) => `<article><p class="day">${esc(d.day)}</p><h3>${esc(d.title)}</h3><ul>${d.items.map((i) => `<li>${esc(i)}</li>`).join("")}</ul></article>`)
          .join("")}</div>
      </section>
      ${how(site)}`,
  });
}

const weekday = (iso: string) => new Date(iso).toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric", timeZone: "UTC" });

function sessionPage(session: Session, id: string, path: string, site: Site, image?: string) {
  const who = first(session.name);
  const when = weekday(session.date);
  const set = (e: Session["exercises"][number]) =>
    `${e.sets} × ${e.reps ?? (e.seconds ? `${e.seconds} s` : "")}${e.load ? ` · ${round(e.load)} ${e.unit ?? "lb"}` : ""}`;
  return layout(site, {
    view: "s",
    title: `Train with ${who}: ${session.title}, ${when}`,
    description: `${who} is training ${session.title} on ${when}. Join with your own weights in ${site.appName}.`,
    path,
    image,
    body: `
      <section class="hero left">
        <p class="eyebrow">${esc(who)} is training</p>
        <h1>${esc(session.title)}</h1>
        <div class="chips"><span>${esc(when)}${session.time ? ` · ${esc(session.time)}` : ""}</span>${session.minutes ? `<span>~${Math.round(session.minutes)} min</span>` : ""}<span>${session.exercises.length} exercises</span></div>
        ${actions(site, [{ href: `/s/${id}.ics`, label: "Add to calendar" }], `Train with ${who}`)}
        <p class="fine">Your weights come from your own numbers, and you'll see each other live as you train.</p>
      </section>
      <section class="block">
        <h2>The session</h2>
        <div class="days"><article><ul>${session.exercises.map((e) => `<li><b>${esc(e.name)}</b> ${esc(set(e))}</li>`).join("")}</ul></article></div>
      </section>
      ${how(site)}`,
  });
}

/** An all-day event on the session's day, so it's in the friend's calendar before they've installed anything. */
export function calendar(session: Session, url: string, site: Site) {
  const day = session.date.slice(0, 10).replaceAll("-", "");
  const next = new Date(Date.parse(session.date.slice(0, 10)) + 86_400_000).toISOString().slice(0, 10).replaceAll("-", "");
  const text = (t: string) => t.replace(/[\\;,]/g, (c) => `\\${c}`).replace(/\r?\n/g, " ");
  return [
    "BEGIN:VCALENDAR", "VERSION:2.0", `PRODID:-//${text(site.appName)}//EN`, "BEGIN:VEVENT",
    `UID:${day}-${url.split("/").pop()}@${new URL(site.origin).host}`, `DTSTAMP:${new Date().toISOString().replace(/[-:]/g, "").slice(0, 15)}Z`,
    `DTSTART;VALUE=DATE:${day}`, `DTEND;VALUE=DATE:${next}`,
    `SUMMARY:${text(`${session.title} with ${first(session.name)}`)}`, `URL:${url}`, `DESCRIPTION:${text(url)}`,
    "END:VEVENT", "END:VCALENDAR", "",
  ].join("\r\n");
}

function invitePage(invite: Invite, code: string, path: string, site: Site, image?: string) {
  const who = first(invite.by);
  const shown = invite.members.slice(0, 5);
  return layout(site, {
    view: "join",
    title: `Join ${invite.group}`,
    description: `${who} invited you to train together in ${site.appName}.`,
    path,
    image,
    body: `
      <section class="hero">
        <div class="faces" aria-hidden="true">${shown.map((m) => `<span>${esc(m.trim()[0]?.toUpperCase() ?? "?")}</span>`).join("")}${
          invite.members.length > shown.length ? `<span class="more">+${invite.members.length - shown.length}</span>` : ""
        }</div>
        <p class="eyebrow">${esc(who)} invited you</p>
        <h1>Join ${esc(invite.group)}</h1>
        <p class="lede">${invite.members.length} ${invite.members.length === 1 ? "person trains" : "people train"} here. See each other's wins, and work out together live.</p>
        ${invite.recent.length ? `<ul class="feed">${invite.recent.map((r) => `<li>${esc(r)}</li>`).join("")}</ul>` : ""}
        <ol class="steps">
          <li><b>Copy your invite</b>
            <button class="code" type="button" data-copy="${esc(code)}" aria-label="Copy the code ${esc(code)}">${esc(code)}<small>Copy</small></button></li>
          <li><b>Get ${esc(site.appName)}</b><span>Free on the App Store.</span></li>
          <li><b>Open it and tap Paste</b><span>Under “Invited by a friend?” on the first screen.</span></li>
        </ol>
        ${actions(site, [])}
        <p class="fine">Already have the app? Open this link on your iPhone and it goes straight to the group.</p>
      </section>`,
  });
}

/**
 * FIT-130: a coach's invite, opened somewhere other than the app (the app takes /c/* itself). FIT-227: a coach with no
 * name (Sign in with Apple without one) is "a coach", never a first word of a fallback.
 */
function coachInvitePage(coach: string | null, path: string, site: Site) {
  const who = coach?.trim() ? first(coach) : null;
  const app = esc(site.appName);
  return layout(site, {
    title: who ? `${who} invited you to train with them` : `You're invited to train with a coach on ${site.appName}`,
    description: `${who ?? "Your coach"} will write your program and follow your training in ${site.appName}.`,
    path,
    body: `
      <section class="hero">
        <p class="eyebrow">${who ? `${esc(who)} invited you` : "You're invited"}</p>
        <h1>${who ? `Train with ${esc(who)} as your coach` : `Train with a coach on ${app}`}</h1>
        <p class="lede">${who ? esc(who) : "Your coach"} writes your program and sees how your sessions go. You log in the app, and you can stop sharing any time.</p>
        <ol class="steps">
          <li><b>Get ${app}</b><span>Free on the App Store.</span></li>
          <li><b>Open this link again on your iPhone</b><span>It opens the app and asks you to allow it.</span></li>
        </ol>
        ${actions(site, [])}
      </section>`,
  });
}

/**
 * FIT-217: where a coach starts. Sign-in, the plan's Checkout and inviting clients are on the dashboard (/app).
 * FIT-242: Clients, which for someone new is the coach start: their sample client (FIT-240) and Start the coach plan.
 */
export const START = "/app/clients";

/**
 * FIT-217: the home page is for coaches, the customer since the pilot (author, 2026-10-22). It says who it's for,
 * what it costs and what to do next, and "Start coaching" leads to the dashboard: sign in, then the coach plan.
 */
function homePage(site: Site) {
  const app = esc(site.appName);
  const chat = [
    { who: "coach", text: "Mike's knee is sore and his squat has stalled. Rebuild next week." },
    { who: "claude", text: "Mike's squat has sat at 245 × 5 for three weeks, and he noted his left knee on Tuesday. Next week: box squats at 225 for 4 × 5 and split squats instead of lunges. Bench and rows stay as they are. Apply it?" },
    { who: "coach", text: "Apply." },
  ];
  return layout(site, {
    title: `${site.appName}: coach your clients from Claude`,
    description: `Your clients log in a free app. You coach them from Claude. $19.99 a month; clients are free.`,
    path: "/",
    body: `${coachStyle}
      <section class="hero">
        <p class="eyebrow">For strength coaches</p>
        <h1>Your clients log in a free app. You coach them from Claude.</h1>
        <p class="lede">Ask Claude to write or change a client's week, and it works from every set they logged. You decide what's saved. The dashboard shows who trained, who's slipping and who's hurting.</p>
        <div class="actions">
          <a class="button primary" href="${START}">Start coaching</a>
          <a class="button" href="#how">How it works</a>
        </div>
      </section>
      <section class="block how" id="how">
        <h2>How it works</h2>
        <ol>
          <li><b>Invite your clients</b><span>They get ${app} free on their iPhone, follow the week you wrote, and log each set.</span></li>
          <li><b>Program in Claude</b><span>Say what you want for a client. Claude reads their logs, proposes the week, and saves it when you say so.</span></li>
          <li><b>See your roster</b><span>Who trained, who's slipping, and who said something hurts, at a glance.</span></li>
        </ol>
      </section>
      <section class="block">
        <h2>Your roster</h2>
        ${rosterFigure()}
        <p class="fine">The dashboard's Clients, those who need you first. Claude reads the same flags when you ask who needs you this week.</p>
      </section>
      <section class="block">
        <h2>What it looks like in Claude</h2>
        <ul class="chat">${chat.map((m) => `<li class="${m.who}">${esc(m.text)}</li>`).join("")}</ul>
        <p class="fine">Mike's phone shows the new week as soon as it's applied.</p>
      </section>
      <section class="block price-block">
        <h2>Price</h2>
        <p class="price"><b>$19.99</b><span>a month, or $199 a year</span></p>
        <p class="lede">Clients are free. Cancel any time from Billing.</p>
      </section>
      <section class="block">
        <h2>What you need</h2>
        <ul class="needs">
          <li><b>Claude</b><span>On claude.ai or the Claude app, with ${app} added as a connector. <a href="/claude">How to connect</a></span></li>
          <li><b>Clients with an iPhone</b><span>${site.appStoreUrl ? `<a href="${esc(site.appStoreUrl)}">${app} on the App Store</a>, free.` : `${app} is free for them; you send each one an invite link.`}</span></li>
        </ul>
      </section>
      <section class="block start">
        <h2>Get started</h2>
        <ol class="steps">
          <li><b>Sign in</b><span>With Google or Apple.</span></li>
          <li><b>Connect Claude</b><span>Paste one address into Claude's connectors, and try it on your sample client.</span></li>
          <li><b>Start the coach plan</b><span>Monthly or yearly, through Stripe.</span></li>
          <li><b>Invite your first client</b><span>Send them the link.</span></li>
        </ol>
        <div class="actions"><a class="button primary" href="${START}">Start coaching</a></div>
      </section>
      <section class="block">
        <h2>Weighing it against another tool?</h2>
        <p class="lede">Side by side with Trainera, TrueCoach, Trainerize, Everfit, TrainHeroic, spreadsheets and more, including where they're better.</p>
        <div class="actions"><a class="button" href="/compare">See the comparisons</a></div>
      </section>
      <section class="block">
        <h2>Training yourself?</h2>
        <p class="lede">${app} is free for you too. Connect Claude and say “Set me up”: it asks about your goals, writes your program, and logs your sessions. Sign in with Google or Apple and your account is made for you.</p>
        <div class="actions"><a class="button" href="/claude">Connect Claude</a></div>
      </section>`,
  });
}

/** FIT-242: the dashboard's Clients as a coach sees it: FIT-221's demo clients and the flags shared/triage.ts gives them. */
function rosterFigure() {
  const rows = [
    { name: "Mike Torres", week: "3 of 3 this week · last Fri", flags: [["pain", "Fri: “Left knee is sore, worse on squats”"], ["hard", "RPE 9+ on Back Squat"], ["plateau", "No new best on Back Squat in 3 weeks"]] },
    { name: "Jen Alvarez", week: "2 of 3 this week · last Wed", flags: [] },
    { name: "Sara Kim", week: "3 of 3 this week · 5 weeks in a row", flags: [] },
  ];
  return `<figure class="roster" aria-label="The dashboard's Clients page">
    <ul>${rows.map((r) => `<li><span class="who"><b>${esc(r.name)}</b><span>${esc(r.week)}</span></span>${r.flags.length
      ? `<span class="flags">${r.flags.map(([kind, text]) => `<span class="${kind}">${esc(text)}</span>`).join("")}</span>`
      : `<span class="flags"><span>No flags</span></span>`}</li>`).join("")}</ul>
  </figure>`;
}

const coachStyle = `<style>
.roster ul{list-style:none;display:grid;gap:8px}
.roster li{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:flex-start;gap:10px;background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:14px 16px}
.roster .who{display:grid;gap:2px}.roster .who span{color:var(--muted);font-size:14px}
.roster .flags{display:flex;flex-wrap:wrap;gap:6px}
.roster .flags span{font-size:13px;padding:3px 10px;border-radius:999px;border:1px solid var(--line);color:var(--muted)}
.roster .flags .pain,.roster .flags .hard{color:#b0541f;border-color:currentColor}
.roster .flags .plateau{color:var(--text);border-color:var(--text)}
@media (prefers-color-scheme:dark){.roster .flags .pain,.roster .flags .hard{color:#f0a46b}}
.chat{list-style:none;display:grid;gap:8px}
.chat li{border-radius:18px;padding:10px 14px;font-size:15px;max-width:88%;width:fit-content}
.chat .coach{justify-self:end;background:var(--button);color:var(--button-text);border-bottom-right-radius:6px}
.chat .claude{background:var(--surface);border:1px solid var(--line);border-bottom-left-radius:6px}
.price{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}.price b{font:700 40px/1 var(--round);letter-spacing:-.02em}.price span{color:var(--muted)}
.price-block .lede{margin-top:8px}
.needs{list-style:none;display:grid;gap:14px}
.needs li{display:flex;flex-direction:column}.needs span{color:var(--muted);font-size:15px}
.start .steps{margin-top:0;max-width:none}
.start .actions{max-width:none}
@media (min-width:700px){.start .actions{max-width:360px}}
</style>`;

/**
 * FIT-152: connecting Claude (or any MCP agent). FIT-217: written for the coach, the last step before inviting
 * clients; it works the same for someone training themselves.
 */
function claudePage(site: Site, mcpUrl: string) {
  const says = [
    "Show me my clients.",
    "Mike's knee is sore and his squat has stalled. Rebuild next week.",
    "Write Sara a 3-day program for her first meet in March.",
    "Who's slipping this week?",
    "Invite a new client.",
  ];
  return layout(site, {
    title: "Connect Claude",
    description: `Connect ${site.appName} to Claude: write and change your clients' training from their logged sets.`,
    path: "/claude",
    linkHome: false,
    body: `
      <section class="hero left">
        <p class="eyebrow">Connect Claude</p>
        <h1>Coach from Claude</h1>
        <p class="lede">Add ${esc(site.appName)} to Claude once. Then ask it to write or change a client's week: it reads what they logged, shows you the plan, and saves it when you say so.</p>
        <ol class="steps">
          <li><b>Copy the connector address</b>
            <button class="code url" type="button" data-copy="${esc(mcpUrl)}" aria-label="Copy the connector address">${esc(mcpUrl)}<small>Copy</small></button></li>
          <li><b>Add it to Claude</b><span>On claude.ai, open Settings › Connectors › Add custom connector. Name it ${esc(site.appName)} and paste the address.</span></li>
          <li><b>Connect and sign in</b><span>Choose Connect, then Google or Apple: the account you coach with, or any account if you're training yourself. A new account is made for you, free.</span></li>
          <li><b>Say “Show me my clients”</b><span>Your roster comes back. Invite clients on the dashboard, or ask Claude for an invite link.</span></li>
        </ol>
        <div class="actions"><a class="button primary" href="https://claude.ai/settings/connectors">Open Claude's connectors</a></div>
        <p class="fine">Once added, it's in the Claude app on your phone too.</p>
      </section>
      <section class="block">
        <h2>Then just say it</h2>
        <ul class="says">${says.map((s) => `<li>${esc(s)}</li>`).join("")}</ul>
        <p class="fine">Claude shows each change before it's saved, and can undo it. Training yourself? The same connector works for you, free: say “Set me up” and Claude writes your program. Other agents that speak MCP connect at the same address. Every tool, and what happens to your data, is in the <a href="/docs">documentation</a>.</p>
      </section>`,
  });
}

/**
 * FIT-190: where Stripe Checkout came back to once Pro was paid for. FIT-214: Pro isn't sold any more, so this only
 * catches a Checkout already under way, and doesn't name or price Pro.
 */
function proThanksPage(site: Site) {
  return layout(site, {
    title: "Thanks",
    description: site.appName,
    path: "/pro/thanks",
    body: `<section class="hero"><h1>You're all set</h1>
      <p class="lede">Go back to Claude and carry on, with nothing to reconnect.</p>
      <div class="actions"><a class="button primary" href="https://claude.ai">Back to Claude</a></div></section>`,
  });
}

export function missingPage(site: Site) {
  return layout(site, {
    title: "This link has expired",
    description: site.appName,
    path: "/",
    body: `<section class="hero"><h1>This link has expired</h1>
      <p class="lede">Whoever shared it may have stopped sharing. You can still start your own program.</p>${actions(site, [])}</section>`,
  });
}

type Action = { href: string; label: string } | undefined | "" | false;

export function actions(site: Site, more: Action[], primary = `Get ${site.appName}`) {
  const store = site.appStoreUrl ?? "#soon";
  const secondary = more.filter((a): a is { href: string; label: string } => !!a);
  return `<div class="actions">
    <a class="button primary" href="${esc(store)}">${esc(primary)}</a>
    ${secondary.map((a) => `<a class="button" href="${esc(a.href)}">${esc(a.label)}</a>`).join("")}
    ${site.appStoreUrl ? "" : `<p class="fine" id="soon">Coming to the App Store soon. Free to download.</p>`}
  </div>`;
}

function how(site: Site) {
  return `<section class="block how">
    <h2>How ${esc(site.appName)} works</h2>
    <ol>
      <li><b>Get a program</b><span>From your coach, written around your goal and your own starting numbers.</span></li>
      <li><b>Log every set</b><span>A tap per set at the gym. The app is free.</span></li>
      <li><b>Watch it climb</b><span>Bests, streaks and each week's weights follow what you actually lifted.</span></li>
    </ol>
  </section>`;
}

export const logo = `<svg class="logo" viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="13" width="5" height="8" rx="1.5"/><rect x="9.5" y="8.5" width="5" height="12.5" rx="1.5"/><rect x="16" y="3" width="5" height="18" rx="1.5"/></svg>`;

/**
 * `linkHome: false` leaves the logo unlinked: on the pages the iPhone app opens (privacy, terms, support, and /claude
 * one tap on), so the app has no path to the home page's coach plan checkout (App Review 3.1.1(a), FIT-59).
 */
export function layout(site: Site, page: { title: string; description: string; path: string; body: string; image?: string; view?: string; linkHome?: boolean }) {
  const url = `${site.origin}${page.path}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(page.title)}</title>
<meta name="description" content="${esc(page.description)}">
<meta property="og:site_name" content="${esc(site.appName)}">
<meta property="og:title" content="${esc(page.title)}">
<meta property="og:description" content="${esc(page.description)}">
<meta property="og:url" content="${esc(url)}">
<link rel="canonical" href="${esc(`${site.home ?? site.origin}${page.path}`)}">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">${
  page.image
    ? `\n<meta property="og:image" content="${esc(page.image)}">${page.image.endsWith("/invite.png") ? "" : `\n<meta property="og:image:width" content="1080">\n<meta property="og:image:height" content="1348">`}\n<meta property="og:image:alt" content="${esc(page.title)}">`
    : ""
}
<meta name="theme-color" content="#f6f6f4" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#111111" media="(prefers-color-scheme: dark)">
<style>${css}</style>
</head>
<body>
<header class="top">${page.linkHome === false ? `<span class="brand">${logo}${esc(site.appName)}</span>` : `<a href="/" class="brand">${logo}${esc(site.appName)}</a>`}</header>
<main>${page.body}</main>
<footer class="foot"><nav><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a></nav>© ${new Date().getUTCFullYear()} ${esc(site.appName)}</footer>
<script>${page.view ? `\nfetch("/v/${page.view}", { cache: "no-store", keepalive: true }).catch(() => {});` : ""}
document.addEventListener("click", async (e) => {
  const b = e.target.closest("[data-copy]");
  if (!b) return;
  try { await navigator.clipboard.writeText(b.dataset.copy); b.querySelector("small").textContent = "Copied"; }
  catch { getSelection().selectAllChildren(b); }
});
</script>
</body>
</html>`;
}

const css = `
:root{--bg:#f6f6f4;--surface:#fff;--text:#111;--muted:#5e5e59;--line:#e3e3df;--accent:#e2475a;--button:#111;--button-text:#fff;
  --sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Arial,sans-serif;--round:ui-rounded,"SF Pro Rounded",var(--sans)}
@media (prefers-color-scheme:dark){:root{--bg:#0b0b0b;--surface:#171717;--text:#f2f2f0;--muted:#a3a39e;--line:#2a2a2a;--button:#f2f2f0;--button-text:#111}}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font:17px/1.45 var(--sans);-webkit-font-smoothing:antialiased;min-height:100vh;display:flex;flex-direction:column}
main{flex:1;width:100%;max-width:560px;margin:0 auto;padding:0 16px}
a{color:inherit}
.top{padding:16px 20px;max-width:560px;margin:0 auto;width:100%}
.brand{display:inline-flex;align-items:center;gap:8px;font-weight:650;text-decoration:none;font-size:16px}
.brand .logo{width:22px;height:22px;fill:var(--accent)}
.hero{display:flex;flex-direction:column;align-items:center;text-align:center;padding:16px 0 40px}
.hero.left{align-items:flex-start;text-align:left}
h1{font-size:30px;line-height:1.12;letter-spacing:-.02em;font-weight:750;margin-top:28px;text-wrap:balance}
.hero.left h1{margin-top:6px}
h2{font-size:21px;letter-spacing:-.01em;margin-bottom:16px}
h3{font-size:17px}
.lede{color:var(--muted);margin-top:12px;max-width:30em;text-wrap:pretty}
.eyebrow{color:var(--muted);font-size:13px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;margin-top:20px}
.fine{color:var(--muted);font-size:14px;margin-top:12px}
.actions{display:flex;flex-direction:column;gap:10px;width:100%;max-width:360px;margin-top:28px}
.hero.left .actions{max-width:none}
.button{display:flex;align-items:center;justify-content:center;gap:8px;min-height:54px;border-radius:999px;font-weight:650;text-decoration:none;
  border:1px solid var(--line);background:var(--surface)}
.button.primary{background:var(--button);color:var(--button-text);border-color:var(--button)}
.button:active{transform:scale(.98)}
.email{width:100%;max-width:360px;margin-top:18px}
.email summary{cursor:pointer;color:var(--muted);font-size:15px}
.email form{display:grid;gap:12px;margin-top:14px;text-align:left}
.email label{display:grid;gap:6px;font-size:14px;color:var(--muted)}
.email input{font:inherit;color:var(--text);min-height:48px;padding:0 16px;border-radius:12px;border:1px solid var(--line);background:var(--surface)}
.email .error{color:var(--accent);font-size:14px}
.email button{width:100%;font:inherit;font-weight:650;color:inherit;cursor:pointer}
.block{padding:32px 0;border-top:1px solid var(--line)}
.how ol,.steps,.phases{list-style:none;display:grid;gap:18px;counter-reset:n}
.how li,.steps li{display:grid;grid-template-columns:32px 1fr;column-gap:12px;counter-increment:n;text-align:left}
.how li::before,.steps li::before{content:counter(n);grid-row:span 2;width:28px;height:28px;border-radius:50%;background:var(--surface);
  border:1px solid var(--line);display:grid;place-items:center;font-size:14px;font-weight:650}
.how span,.steps span{color:var(--muted);font-size:15px}
.foot{color:var(--muted);font-size:13px;text-align:center;padding:24px 16px calc(24px + env(safe-area-inset-bottom))}
.foot nav{display:flex;justify-content:center;gap:20px;margin-bottom:8px}.foot nav a{color:inherit}

/* The win card: fixed colors, as in the app. */
.card{--c-bg:#111;--c-text:#fff;--c-muted:#b5b5b0;--c-soft:#d6d6d1;--c-track:#3a3a3d;
  width:min(100%,340px);aspect-ratio:306/382;border-radius:22px;padding:26px 26px 22px;background:var(--c-bg);color:var(--c-text);
  display:flex;flex-direction:column;text-align:left;box-shadow:0 10px 30px rgba(0,0,0,.16)}
@media (prefers-color-scheme:dark){.card:not(.paper),.recap{border:1px solid #2c2c2e}}
.card.paper{--c-bg:#f6f6f4;--c-text:#111;--c-muted:#5e5e59;--c-soft:#40403d;--c-track:#dbdbd9;border:1px solid var(--c-track)}
.card .tag,.recap .tag{font-size:11px;font-weight:650;letter-spacing:.11em;color:var(--c-muted,var(--muted))}
.card .heading{font-size:19px;font-weight:650;margin-top:4px}
.card .big{display:flex;align-items:baseline;gap:6px;margin-top:26px}
.card .big b{font:700 84px/1 var(--round);letter-spacing:-.03em}
.card .big span{font-size:22px;font-weight:600;color:var(--c-muted)}
.card .sub{color:var(--c-soft);font-size:15px;margin-top:8px}
.card .sub.center{text-align:center}
.card .grow{flex:1}
.card .spark{width:100%;height:70px;color:var(--c-text)}
.card .weeks{display:flex;gap:6px}.card .weeks i{flex:1;height:36px;border-radius:8px;background:var(--c-text)}
.card .ringwrap{position:relative;width:170px;height:170px;margin:auto}
.card .ring{width:100%;height:100%;color:var(--c-text)}.card .ring .track{stroke:var(--c-track)}
.card .ringtext{position:absolute;inset:0;display:grid;place-content:center;text-align:center}
.card .ringtext b{font:700 40px/1 var(--round);letter-spacing:-.02em}.card .ringtext span{font-size:13px;color:var(--c-muted)}
.card footer,.recap footer{display:flex;justify-content:space-between;align-items:center;font-size:12px;color:var(--c-muted,var(--muted));margin-top:14px}
.mark{display:inline-flex;align-items:center;gap:5px;font-weight:650}.mark .logo{width:13px;height:13px;fill:currentColor}

/* The recap card. */
.recap{width:min(100%,360px);border-radius:22px;padding:24px;background:#111;color:#fff;text-align:left;box-shadow:0 10px 30px rgba(0,0,0,.16);--c-muted:#b5b5b0}
.recap-week{display:flex;align-items:baseline;gap:8px;margin-top:10px}
.recap-week b{font:700 72px/1 var(--round);letter-spacing:-.03em}.recap-week span{color:#b5b5b0;font-size:18px;font-weight:600}
.bar{height:8px;border-radius:4px;background:#3a3a3d;margin-top:16px;overflow:hidden}.bar i{display:block;height:100%;background:#fff;border-radius:4px}
.tiles{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:18px}
.tiles div{background:#1f1f21;border-radius:14px;padding:12px 14px;display:flex;flex-direction:column}
.tiles b{font:700 26px/1.1 var(--round)}.tiles span{color:#b5b5b0;font-size:13px}
.lifts{list-style:none;margin-top:14px;display:grid;gap:2px}
.lifts li{display:grid;grid-template-columns:1fr auto;padding:10px 0;border-bottom:1px solid #2a2a2c}
.lifts li:last-child{border-bottom:0}
.lifts b{font:650 17px var(--round)}.lifts b.up{color:#8fe3a8}
.lifts small{grid-column:1/-1;color:#b5b5b0;font-size:13px}

/* The program. */
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}
.chips span{border:1px solid var(--line);background:var(--surface);border-radius:999px;padding:5px 12px;font-size:14px;font-weight:550}
.goals{margin-top:16px;color:var(--muted)}.goals b{color:var(--text)}
.phases li{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:16px 18px;border-left:4px solid var(--accent)}
.phases p{color:var(--muted);font-size:15px;margin-top:2px}
.weeks-label{font-size:12px;font-weight:650;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.phases .lifts-line{color:var(--text);font-weight:550;margin-top:8px}.phases .lifts-line span{color:var(--muted)}
.days{display:grid;gap:12px}
.days article{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:16px 18px}
.days .day{font-size:12px;font-weight:650;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.days ul{list-style:none;margin-top:8px;display:grid;gap:4px;color:var(--muted);font-size:15px}

/* The invite. */
.faces{display:flex;margin-top:12px}
.faces span{width:52px;height:52px;border-radius:50%;display:grid;place-items:center;font-weight:700;font-size:20px;
  background:var(--surface);border:3px solid var(--bg);margin-left:-12px;box-shadow:0 0 0 1px var(--line)}
.faces span:first-child{margin-left:0;background:var(--accent);color:#fff}
.faces .more{font-size:15px;color:var(--muted)}
.feed{list-style:none;margin-top:20px;width:100%;max-width:360px;display:grid;gap:8px}
.feed li{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:10px 14px;font-size:15px;text-align:left}
.feed li::before{content:"🏆 "}
.steps{margin-top:28px;width:100%;max-width:360px}
.code{grid-column:2;margin-top:8px;display:flex;align-items:center;justify-content:space-between;width:100%;padding:12px 16px;
  font:700 26px var(--round);letter-spacing:.18em;color:var(--text);background:var(--surface);border:1.5px dashed var(--muted);border-radius:14px;cursor:pointer}
.code small{font:600 14px var(--sans);letter-spacing:0;color:var(--accent)}
.code.url{font:600 15px/1.3 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:0;gap:12px;text-align:left;overflow-wrap:anywhere}
.code.url small{flex:none}
.hero.left .steps{max-width:none}
.says{list-style:none;display:grid;gap:8px}
.says li{background:var(--surface);border:1px solid var(--line);border-radius:18px 18px 18px 6px;padding:10px 14px;font-size:15px;width:fit-content;max-width:100%}
/* FIT-236: the connector's documentation (mcpDocs.ts). */
.doc{text-align:left}
.doc p,.doc ul,.doc ol{margin-top:12px;font-size:16px}
.doc ul,.doc ol{padding-left:20px;display:grid;gap:8px}
.doc h3{margin-top:28px}
.doc .code{grid-column:auto}
.doc code{font:600 14px ui-monospace,SFMono-Regular,Menlo,monospace}
.tools,.says-list{margin-top:12px;display:grid;gap:4px}
.tools dt,.says-list dt{font-weight:650;margin-top:12px}
.tools dd,.says-list dd{color:var(--muted);font-size:15px}
.tag{display:inline-block;margin-left:6px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);font-size:12px;font-weight:600;color:var(--muted);vertical-align:2px}
@media (min-width:700px){h1{font-size:38px}.days{grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}}
`;
