// FIT-177: timed-distance goals ("10K in 55:00") and the runs that move them. A goal is metric run_<meters>m.time_s
// in seconds, lower being better; a run is a workout entry on one of the catalog's runs with distance_m and
// duration_s (and hr_avg). Its predicted race time is Riegel's: T2 = T1 × (D2 / D1)^1.06.

/** The catalog's runs: outdoors first, the default. */
export const RUNS = ["trail-running-walking", "running-treadmill", "jogging-treadmill"];
export const OUTDOOR_RUN = RUNS[0];

const RACES: Record<string, number> = { "5k": 5000, "10k": 10000, half: 21097.5, "half marathon": 21097.5, marathon: 42195 };

export const MILE = 1609.344;

/** "10K", "half", "8 km", "5 mi", "5000 m" or a number of miles (FIT-186: the app's runs are in miles), in meters. */
export function meters(said: string | number): number {
  if (typeof said === "number") {
    if (!(said > 0 && said < 250)) throw new Error("A distance is in miles, e.g. 5, or \"10K\".");
    return said * MILE;
  }
  const s = said.trim().toLowerCase().replace(/[\s-]+/g, " ");
  if (RACES[s] ?? RACES[s.replace(/ /g, "")]) return RACES[s] ?? RACES[s.replace(/ /g, "")];
  const m = /^(\d+(?:\.\d+)?)\s*(k|km|kilometers?|mi|miles?|m|meters?)?$/.exec(s);
  if (!m) throw new Error(`Not a distance: ${said}. Say "5 mi", "10K", "half" or "8 km".`);
  const n = Number(m[1]), unit = m[2] ?? "mi";
  return unit.startsWith("mi") ? n * MILE : unit === "m" || unit.startsWith("meter") ? n : n * 1000;
}

/** "55:00", "1:45:30", "48 min", "3300 s" or a number of minutes, in seconds. */
export function seconds(said: string | number): number {
  if (typeof said === "number") {
    if (!(said > 0 && said < 24 * 60)) throw new Error("A time is in minutes, e.g. 55, or \"55:00\".");
    return Math.round(said * 60);
  }
  const s = said.trim().toLowerCase();
  const clock = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/.exec(s);
  if (clock) return clock[3] !== undefined ? Number(clock[1]) * 3600 + Number(clock[2]) * 60 + Number(clock[3]) : Number(clock[1]) * 60 + Number(clock[2]);
  const unit = /^(\d+(?:\.\d+)?)\s*(h|hours?|min|mins|minutes?|s|sec|seconds?)$/.exec(s);
  if (!unit) throw new Error(`Not a time: ${said}. Say "55:00", "1:45:30" or "48 min".`);
  const n = Number(unit[1]);
  return Math.round(unit[2].startsWith("h") ? n * 3600 : unit[2].startsWith("s") ? n : n * 60);
}

/** "54:30", "1:45:30". */
export function clock(total: number) {
  const t = Math.round(total), h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

/** FIT-186: "5 mi", to a tenth, as the app shows a run. */
export const miles = (m: number) => `${Math.round((m / MILE) * 10) / 10} mi`;

/** "8:51/mi". */
export const pace = (secs: number, m: number) => `${clock(secs / (m / MILE))}/mi`;

export const runMetric = (m: number) => `run_${Math.round(m)}m.time_s`;
/** The goal distance of a run metric, in meters. */
export function goalMeters(metric: string) {
  const m = /^run_(\d+)m\.time_s$/.exec(metric);
  return m ? Number(m[1]) : undefined;
}

/** "10K", "Half marathon", "5 mi". */
export function distanceName(m: number) {
  if (Math.abs(m - 42195) < 1) return "Marathon";
  if (Math.abs(m - 21098) < 2) return "Half marathon";
  return m % 1000 === 0 && m <= 50000 ? `${m / 1000}K` : miles(m);
}

/** Riegel: a run's time carried to another distance. Only runs a quarter of it or longer, and a mile or longer, count. */
export function riegel(time: number, from: number, to: number) {
  return from >= Math.max(1600, to / 4) ? time * (to / from) ** 1.06 : undefined;
}
