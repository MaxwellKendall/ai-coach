import type { LogRow, Measurement } from "./sync";

// FIT-200: correcting what was logged, from the dashboard: a set's numbers, the session's note, or the whole session.
// Rows keep every field the app wrote (a run's route…), so a correction changes only what it says. The app applies a
// log# unit row by row (Core/Cloud/SyncUnits.swift `apply`), so the phone shows each change on its next sync.

/** A set's numbers as typed; null clears one, a missing one is left as it was. */
export type SetFix = { load?: number | null; reps?: number | null; seconds?: number | null; rpe?: number | null };

const value = (row: LogRow, metric: string) => row.measurements.find((m) => m.metric === metric)?.value;

/** The summary row the app saves after a session's sets (WorkoutDraft.save): no exercise, the session's note. */
const isSummary = (r: LogRow) => r.kind === "workout" && !r.template;

/** A set the editor can change: an exercise's row that isn't a run (runs keep their distance and route). */
export const isSet = (r: LogRow) => r.kind === "workout" && !!r.template && value(r, "distance_m") === undefined;

/** What the editor shows for a set: its load (lb or lb/hand), reps or seconds, and RPE. */
export function setFields(row: LogRow) {
  const hand = value(row, "load_lb_hand") !== undefined;
  const timed = value(row, "reps") === undefined && value(row, "duration_s") !== undefined;
  return {
    load: value(row, hand ? "load_lb_hand" : "load_lb"),
    loadUnit: hand ? "lb/hand" : "lb",
    timed,
    count: value(row, timed ? "duration_s" : "reps"),
    rpe: value(row, "rpe"),
  };
}

export function fixSet(rows: LogRow[], id: string, fix: SetFix): LogRow[] {
  return rows.map((row) => {
    if (row.id !== id) return row;
    const fields = setFields(row);
    const metrics: [keyof SetFix, Measurement][] = [
      ["load", { metric: fields.loadUnit === "lb/hand" ? "load_lb_hand" : "load_lb", value: 0, unit: fields.loadUnit }],
      ["reps", { metric: "reps", value: 0, unit: "reps" }],
      ["seconds", { metric: "duration_s", value: 0, unit: "s" }],
      ["rpe", { metric: "rpe", value: 0, unit: "rpe" }],
    ];
    let measurements = row.measurements;
    for (const [field, blank] of metrics) {
      const next = fix[field];
      if (next === undefined) continue;
      const kept = measurements.find((m) => m.metric === blank.metric);
      measurements = next === null
        ? measurements.filter((m) => m.metric !== blank.metric)
        : kept ? measurements.map((m) => (m.metric === blank.metric ? { ...m, value: next } : m)) : [...measurements, { ...blank, value: next }];
    }
    return { ...row, measurements };
  });
}

export const removeSet = (rows: LogRow[], id: string) => rows.filter((r) => r.id !== id);

/** The day without its workout: every set, run and the summary. Meals, sleep and weight stay. */
export const clearSession = (rows: LogRow[]) => rows.filter((r) => r.kind !== "workout");

/**
 * The client's note on the session: the summary's, as the server reads it (training.ts describeLog). Sessions saved
 * before FIT-28 kept the session's name there, which isn't a note (the app's DayCard says the same).
 */
export function sessionNote(rows: LogRow[], title?: string): string {
  const names = new Set([title, ...rows.filter((r) => !isSummary(r)).map((r) => r.note)]);
  return [...new Set(rows.filter(isSummary).map((r) => r.note).filter((n) => n && !names.has(n)))].join(" ");
}

/** The day with the session's note changed, or removed when empty; a session logged without a summary gets one. */
export function withNote(rows: LogRow[], note: string, title?: string, id: string = crypto.randomUUID()): LogRow[] {
  const text = note.trim();
  const shown = sessionNote(rows, title);
  const summaries = rows.filter(isSummary);
  if (!summaries.length) {
    if (!text) return rows;
    const at = Math.max(...rows.filter((r) => r.kind === "workout").map((r) => r.at)) + 1;
    return [...rows, { id, kind: "workout", at, measurements: [], note: text }];
  }
  // The note goes on the first summary that had it (or the first); others that showed it are cleared.
  const target = summaries.find((r) => r.note && shown.includes(r.note)) ?? summaries[0];
  return rows.map((r) => {
    if (r === target) return { ...r, note: text };
    return isSummary(r) && r.note && shown.includes(r.note) ? { ...r, note: "" } : r;
  });
}
