import { WARMUP } from "./program";
import type { Measurement, PlanRow } from "./sync";

// FIT-128: editing a day's session on the web. A day is its plan# unit, rows in time order (the app keeps the order with
// second offsets, Planner.activity). The editor works on lines: a working exercise and its sets, as program.ts shows
// them; warm-ups are kept as they are. Every edit returns the day's new rows, pinned like an edit in the app
// (ProgramScreen: an edited session is pinned, so planning the week again keeps it). Pure, so it's tested without a server.

export type Edit = { sets: number; reps?: number; seconds?: number; load?: number; rpe?: number };
export type EditLine = {
  /** Rows this line stands for, in order. */
  ids: string[];
  template?: string;
  sets: number;
  targets: Measurement[];
  note: string;
};

const value = (targets: Measurement[], metric: string) => targets.find((m) => m.metric === metric)?.value;
const working = (row: PlanRow) => row.kind === "workout" && row.note !== WARMUP;
const same = (a: Measurement[], b: Measurement[]) => JSON.stringify(a) === JSON.stringify(b);
const ordered = (rows: PlanRow[]) => [...rows].sort((a, b) => a.at - b.at);

/** The working sets, one line per run of rows with the same exercise, targets and note. */
export function editLines(rows: PlanRow[]): EditLine[] {
  const out: EditLine[] = [];
  for (const row of ordered(rows).filter(working)) {
    const targets = row.targets.filter((m) => m.metric !== "sets");
    const sets = value(row.targets, "sets") ?? 1;
    const last = out[out.length - 1];
    if (last && last.template === row.template && same(last.targets, targets) && last.note === row.note) {
      last.ids.push(row.id);
      last.sets += sets;
    } else {
      out.push({ ids: [row.id], template: row.template, sets, targets, note: row.note });
    }
  }
  return out;
}

/** Rows renumbered from the session's start minute, one second apart, in the given order. */
function renumber(rows: PlanRow[]): PlanRow[] {
  if (rows.length === 0) return rows;
  const start = Math.floor(Math.min(...rows.map((r) => r.at)) / 60) * 60;
  return rows.map((row, i) => ({ ...row, at: start + i }));
}

const pin = (rows: PlanRow[]) => rows.map((row) => ({ ...row, pinned: true }));

/** The targets an edit asks for, keeping the line's own kinds: a timed set stays timed, a per-hand load per hand. */
export function targetsFor(line: EditLine, edit: Edit): Measurement[] {
  const out: Measurement[] = [{ metric: "sets", value: Math.max(1, Math.round(edit.sets)), unit: "sets" }];
  const timed = value(line.targets, "duration_s") !== undefined;
  if (timed && edit.seconds) out.push({ metric: "duration_s", value: edit.seconds, unit: "s" });
  if (!timed && edit.reps) out.push({ metric: "reps", value: edit.reps, unit: "reps" });
  const distance = line.targets.find((m) => m.metric === "distance_m");
  if (distance) out.push(distance);
  const perHand = value(line.targets, "load_lb_hand") !== undefined;
  if (edit.load && edit.load > 0) out.push(perHand ? { metric: "load_lb_hand", value: edit.load, unit: "lb/hand" } : { metric: "load_lb", value: edit.load, unit: "lb" });
  if (edit.rpe) out.push({ metric: "rpe", value: edit.rpe, unit: "rpe" });
  return out;
}

/** A line set to `edit`: its first row carries all the sets, the line's other rows go. */
export function editLine(rows: PlanRow[], line: EditLine, edit: Edit): PlanRow[] {
  const [first, ...rest] = line.ids;
  const gone = new Set(rest);
  const targets = targetsFor(line, edit);
  return pin(rows.filter((r) => !gone.has(r.id)).map((r) => (r.id === first ? { ...r, targets, adjustedReason: "edited" } : r)));
}

/** Each line with the warm-up rows of the same exercise just before it: what moves or goes with the line. */
function blocks(rows: PlanRow[]): { line?: EditLine; rows: PlanRow[] }[] {
  const lines = editLines(rows);
  const lineOf = new Map(lines.flatMap((l) => l.ids.map((id) => [id, l] as const)));
  const out: { line?: EditLine; rows: PlanRow[] }[] = [];
  let warmups: PlanRow[] = [];
  for (const row of ordered(rows)) {
    const line = lineOf.get(row.id);
    if (!line) {
      warmups.push(row);
      continue;
    }
    const last = out[out.length - 1];
    if (last?.line === line) {
      last.rows.push(...warmups, row);
    } else {
      const own = warmups.filter((w) => w.template === row.template);
      if (warmups.length > own.length) out.push({ rows: warmups.filter((w) => w.template !== row.template) });
      out.push({ line, rows: [...own, row] });
    }
    warmups = [];
  }
  if (warmups.length) out.push({ rows: warmups });
  return out;
}

export function removeLine(rows: PlanRow[], line: EditLine): PlanRow[] {
  return pin(renumber(blocks(rows).filter((b) => b.line?.ids[0] !== line.ids[0]).flatMap((b) => b.rows)));
}

/** Moves a line, with its warm-ups, one place up or down among the lines. */
export function moveLine(rows: PlanRow[], line: EditLine, by: -1 | 1): PlanRow[] {
  const all = blocks(rows);
  const withLines = all.map((b, i) => [b, i] as const).filter(([b]) => b.line);
  const at = withLines.findIndex(([b]) => b.line!.ids[0] === line.ids[0]);
  const to = at + by;
  if (at < 0 || to < 0 || to >= withLines.length) return rows;
  const order = [...all];
  [order[withLines[at][1]], order[withLines[to][1]]] = [order[withLines[to][1]], order[withLines[at][1]]];
  return pin(renumber(order.flatMap((b) => b.rows)));
}

/** A new exercise at the end of the session: 3 × 10, no load, until it's edited. */
export function addLine(rows: PlanRow[], template: string, slot: string | undefined, dayStart: number, id: string = crypto.randomUUID()): PlanRow[] {
  const last = ordered(rows).at(-1);
  const row: PlanRow = {
    id,
    kind: "workout",
    at: last ? last.at + 1 : dayStart + 7 * 3600,
    slot: last?.slot ?? slot,
    template,
    targets: [{ metric: "sets", value: 3, unit: "sets" }, { metric: "reps", value: 10, unit: "reps" }],
    note: "",
    adjustedReason: "edited",
    main: false,
    pinned: true,
  };
  return pin([...ordered(rows), row]);
}

/** An edit read from what's in the line now, for the inputs. */
export function editOf(line: EditLine): Edit {
  return {
    sets: line.sets,
    reps: value(line.targets, "reps"),
    seconds: value(line.targets, "duration_s"),
    load: value(line.targets, "load_lb") ?? value(line.targets, "load_lb_hand"),
    rpe: value(line.targets, "rpe"),
  };
}
