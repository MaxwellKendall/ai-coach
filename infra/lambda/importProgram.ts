import type { AppSyncIdentityCognito, AppSyncResolverEvent } from "aws-lambda";
import { allowance, apiKey } from "./aiProxy.ts";
import { applyProposal, dynamoStore, propose, type Account, type DayInput, type Store } from "./mcp.ts";
import { addDays, catalog, dayOf, encode, exerciseBody, maxOf, PATTERNS, profileOf, resolve, slugFor, useAccountExercises, type ExerciseInput } from "./training.ts";

/**
 * FIT-290: a coach's existing program, pasted from Excel or Google Sheets (cells arrive tab-separated) or read from a
 * CSV, becomes a client's weeks. Claude Haiku reads the sheet into propose_week's days (business model v2: import is
 * the free dashboard's first job, on our tokens, capped per coach); from there it's the connector's path: names
 * matched to the catalog (FIT-218), percentages to weights from their maxes, the plan rules checked, a proposal the
 * dashboard previews, and apply.
 */

export const MODEL = "claude-haiku-5-5";
export const MAX_CHARS = 40_000;
/** FIT-291: a PDF's size, as AppSync carries it base64 in one request (about 1 MB). */
export const MAX_PDF_BYTES = 700_000;
/** Imports a coach gets a month (UTC). */
export const MONTHLY_IMPORTS = 30;

const exercise = {
  type: "object",
  properties: {
    exercise: { type: "string", description: "The exercise's name as the sheet writes it, abbreviations expanded where obvious (RDL, OHP, DB…)." },
    sets: { type: "integer", minimum: 1, maximum: 10 },
    reps: { type: "integer", minimum: 1, maximum: 50, description: "For a range (8-10), the low end; the range goes in note." },
    seconds: { type: "integer", description: "For a hold or timed set, instead of reps." },
    weight_lb: { type: "number", description: "A weight the sheet gives in pounds (convert kg × 2.2046)." },
    percent_1rm: { type: "number", description: "A weight the sheet gives as a percentage of the max, instead of weight_lb." },
    rpe: { type: "number", minimum: 5, maximum: 10 },
    superset: { type: "integer", description: "The same number on exercises done together (A1/A2 → 1)." },
    note: { type: "string", description: "Anything else the sheet says about it: tempo, a rep range, AMRAP, cues." },
    pattern: { type: "string", enum: PATTERNS, description: "Its movement pattern, used only if the exercise is new to the app." },
  },
  required: ["exercise", "sets"],
};

export const TOOL = {
  name: "program",
  description: "The program in the sheet, as training days.",
  input_schema: {
    type: "object",
    properties: {
      days: {
        type: "array",
        items: {
          type: "object",
          properties: {
            week: { type: "integer", minimum: 1, maximum: 16, description: "1 for the first week. A sheet that gives one week only is week 1." },
            weekday: { type: "integer", minimum: 1, maximum: 7, description: "1 Monday … 7 Sunday. Day 1, Day 2… without weekdays: spread them Monday, Wednesday, Friday for 3 days; Monday, Tuesday, Thursday, Friday for 4." },
            title: { type: "string", description: "The day's name in the sheet (Lower A, Push), or a short one." },
            exercises: { type: "array", items: exercise },
          },
          required: ["week", "weekday", "exercises"],
        },
      },
    },
    required: ["days"],
  },
};

export const SYSTEM = `You read a strength coach's training program, pasted from a spreadsheet or CSV, and return it with the program tool, exactly as written: every week, day and exercise, in order, with its sets, reps, weight or percentage, RPE and notes. Don't add, drop or change anything, and don't invent weights. If a block repeats for several weeks with only the weights or reps changing, return each week. Ignore columns for the client's logged results.`;

type Imported = ExerciseInput & { pattern?: string };
type Parsed = { days?: { week?: number; weekday?: number; title?: string; exercises?: Imported[] }[] };

/** The model's weeks and weekdays as dates, from the Monday the program starts. Weeks past 16 are dropped. */
export function toDays(parsed: Parsed, monday: string): DayInput[] {
  const days = new Map<string, DayInput>();
  for (const d of parsed.days ?? []) {
    const week = Math.round(d.week ?? 1), weekday = Math.round(d.weekday ?? 1);
    if (week < 1 || week > 16 || weekday < 1 || weekday > 7 || !d.exercises?.length) continue;
    const date = addDays(monday, (week - 1) * 7 + weekday - 1);
    const day = days.get(date) ?? { date, title: d.title?.trim() || undefined, exercises: [] };
    day.exercises.push(...d.exercises.map(({ pattern, ...x }) => x));
    days.set(date, day);
  }
  return [...days.values()].sort((a, b) => a.date.localeCompare(b.date));
}

/** Names the catalog (and their own exercises) can't place, with the pattern the model gave: these become theirs. */
export function unmatched(parsed: Parsed): Map<string, string> {
  const out = new Map<string, string>();
  for (const d of parsed.days ?? []) for (const x of d.exercises ?? []) {
    try { resolve(x.exercise); } catch { out.set(x.exercise.trim(), PATTERNS.includes(x.pattern ?? "") ? x.pattern! : "core"); }
  }
  return out;
}

/** A percentage with no max to take it from stays a note, rather than failing the whole import. */
export function keepPercents(days: DayInput[], maxFor: (exercise: string) => number | undefined): DayInput[] {
  return days.map((d) => ({
    ...d,
    exercises: d.exercises.map((x) => {
      if (x.percent_1rm === undefined) return x;
      if (x.weight_lb !== undefined) return { ...x, percent_1rm: undefined };
      if (maxFor(x.exercise) !== undefined) return x;
      return { ...x, percent_1rm: undefined, note: [`${x.percent_1rm}% of max`, x.note].filter(Boolean).join(". ") };
    }),
  }));
}

/**
 * FIT-291: a Google Sheets link as its CSV export, the tab it points at (gid) or the first. Only docs.google.com
 * sheets, so the server never fetches anywhere else.
 */
export function sheetCsvUrl(link: string): string | undefined {
  let url: URL;
  try { url = new URL(link.trim()); } catch { return undefined; }
  const id = url.pathname.match(/^\/spreadsheets\/d\/([A-Za-z0-9_-]{20,})/)?.[1];
  if (url.protocol !== "https:" || url.hostname !== "docs.google.com" || !id) return undefined;
  const gid = (url.hash.match(/gid=(\d+)/) ?? url.search.match(/gid=(\d+)/))?.[1] ?? "0";
  return `https://docs.google.com/spreadsheets/d/${id}/export?format=csv&gid=${gid}`;
}

const PRIVATE_SHEET = "Couldn't open that sheet. Share it with \"Anyone with the link\" (Share › General access), or copy the cells and paste them.";

/** A shared sheet's tab as CSV. A private one answers with Google's sign-in page, not CSV. */
export async function fetchSheet(link: string, get: typeof fetch = fetch): Promise<string> {
  const url = sheetCsvUrl(link);
  if (!url) throw new Error("That isn't a Google Sheets link. It looks like https://docs.google.com/spreadsheets/d/…");
  const response = await get(url, { redirect: "follow" });
  const type = response.headers.get("content-type") ?? "";
  if (!response.ok || !type.includes("text/csv")) throw new Error(PRIVATE_SHEET);
  return response.text();
}

/** FIT-291: an uploaded PDF, base64, checked before it costs anything. */
export function checkPdf(base64: string) {
  const bytes = Buffer.from(base64, "base64");
  if (bytes.length > MAX_PDF_BYTES) throw new Error(`That PDF is too big to import here (${Math.round(MAX_PDF_BYTES / 1000)} KB at most). Import a few weeks at a time, or paste the cells.`);
  if (bytes.subarray(0, 4).toString("latin1") !== "%PDF") throw new Error("That file isn't a PDF.");
}

/** What the coach gave: pasted cells or a CSV's text, a PDF (base64), or a Google Sheets link. */
export type Source = { text?: string | null; pdf?: string | null; sheet?: string | null };

/** The Monday of the week holding day (YYYY-MM-DD). */
export function mondayOf(day: string) {
  const weekday = (new Date(`${day}T12:00:00Z`).getUTCDay() + 6) % 7;
  return addDays(day, -weekday);
}

type Content = string | Record<string, unknown>[];

async function read(content: Content): Promise<{ parsed: Parsed; usage?: { input_tokens: number; output_tokens: number } }> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": await apiKey(), "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: 8_000, system: SYSTEM, tools: [TOOL], tool_choice: { type: "tool", name: TOOL.name },
      messages: [{ role: "user", content }] }),
  });
  const body = await response.json();
  if (!response.ok) throw new Error(`Couldn't read the program just now (${body?.error?.message ?? response.status}). Try again.`);
  const used = (body.content ?? []).find((c: { type: string }) => c.type === "tool_use");
  if (!used) throw new Error("Couldn't find a program in that. Paste the cells with the exercises, sets and reps.");
  return { parsed: used.input as Parsed, usage: body.usage };
}

export async function importProgram(caller: string, uid: string, source: Source | string, start: string, tz: string, store: Store, now = new Date(),
                                    reader = read, count = (coach: string) => allowance(coach, `AIIMPORT#${now.toISOString().slice(0, 7)}`, MONTHLY_IMPORTS),
                                    get: typeof fetch = fetch) {
  if (uid !== caller && !(await store.coachOf(caller, uid))) throw new Error("You don't coach this person.");
  const given: Source = typeof source === "string" ? { text: source } : source;
  if (given.pdf) checkPdf(given.pdf);
  const today = dayOf(now, tz);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || start < today) throw new Error("Pick a start day from today on.");
  // A sheet's fetched before the allowance counts, so a private one costs nothing.
  const pasted = (given.sheet?.trim() ? await fetchSheet(given.sheet, get) : given.text ?? "").trim();
  if (!given.pdf) {
    if (!pasted) throw new Error(given.sheet ? "That sheet's tab is empty." : "Paste the program first.");
    if (pasted.length > MAX_CHARS) throw new Error(`That's too long to import at once (${MAX_CHARS.toLocaleString("en-US")} characters). Import a few weeks at a time.`);
  }
  if (!(await count(caller))) throw new Error(`That's this month's ${MONTHLY_IMPORTS} imports. More next month.`);
  const content: Content = given.pdf
    ? [{ type: "document", source: { type: "base64", media_type: "application/pdf", data: given.pdf } }, { type: "text", text: "The program is in this PDF." }]
    : pasted;
  const { parsed, usage } = await reader(content);
  let units = await store.units(uid);
  useAccountExercises(units);
  const monday = mondayOf(start);
  let days = toDays(parsed, monday).filter((d) => d.date >= today);
  if (!days.length) throw new Error("Couldn't find any training days in that. Paste the cells with the exercises, sets and reps.");
  // Exercises the catalog doesn't have become theirs, as create_exercise makes them.
  const missing = unmatched(parsed);
  if (missing.size) {
    const taken = new Set(catalog.map((e) => e.slug));
    await store.write(uid, [...missing].map(([name, pattern]) => {
      const body = exerciseBody(undefined, { name, pattern });
      const slug = slugFor(body.name, taken);
      taken.add(slug);
      return { key: `template#${slug}`, body: encode(body) };
    }), "dashboard", caller);
    units = await store.units(uid);
    useAccountExercises(units);
  }
  const profile = profileOf(units);
  days = keepPercents(days, (said) => maxOf(units, profile, resolve(said).slug, today));
  const preview = await propose(uid, caller, tz, today, days, "Imported from a spreadsheet", store);
  const id = preview.match(/^Proposal (\S+)/)?.[1];
  if (!id) throw new Error("Couldn't lay that program out. Try again.");
  if (usage) console.log(JSON.stringify({ import: { coach: caller, from: given.pdf ? "pdf" : given.sheet ? "sheet" : "paste", days: days.length, ...usage } })); // FIT-290: the cost per import
  return { id, preview, days: days.length, added: [...missing.keys()] };
}

export async function handler(event: AppSyncResolverEvent<Record<string, string>>) {
  const caller = (event.identity as AppSyncIdentityCognito | null)?.sub;
  if (!caller) throw new Error("Sign in first.");
  const args = event.arguments;
  const tz = args.tz || "UTC";
  if (event.info.fieldName === "importProgram") return importProgram(caller, args.uid, { text: args.text, pdf: args.pdf, sheet: args.sheet }, args.start, tz, dynamoStore);
  if (event.info.fieldName === "applyImport") {
    if (args.uid !== caller && !(await dynamoStore.coachOf(caller, args.uid))) throw new Error("You don't coach this person.");
    const account: Account = { uid: caller, tz, agent: "dashboard" };
    return (await applyProposal(args.id, args.uid, account, dynamoStore, new Date(), { allowProblems: true })).length;
  }
  throw new Error(`Unknown field ${event.info.fieldName}`);
}
