import catalog from "./catalog.json";
import { estimated1RMs, estimated1RMTrend, loggedSets, streakLine, streakNow } from "./progress";
import type { LogRow, PlanRow, Unit } from "./sync";

// FIT-129: what was logged, newest first, and how the lifts and goals are moving. Derived from the synced units, never
// stored. Takes any account's units, so a coach's client page (FIT-132) shows the same thing.

const names = new Map(catalog.map((t) => [t.slug, t.name]));
const name = (slug?: string) => (slug && names.get(slug)) ?? slug ?? "Exercise";
const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric" });
const parse = (key: string) => {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
};
const round = (n: number) => Math.round(n);
const value = (row: LogRow, metric: string) => row.measurements.find((m) => m.metric === metric)?.value;

type Goal = { kind: string; metric: string; target: number; unit: string; deadline?: number; baseline?: number; status: string };

/** "185 × 5", "BW × 12", "45 s", "8 @ RPE 9". */
function setText(row: LogRow) {
  const load = value(row, "load_lb") ?? value(row, "load_lb_hand");
  const reps = value(row, "reps"), seconds = value(row, "duration_s"), meters = value(row, "distance_m"), rpe = value(row, "rpe");
  const what = reps !== undefined ? `${reps}` : seconds !== undefined ? `${seconds} s` : meters !== undefined ? `${meters} m` : "";
  let text = load ? `${load} × ${what}` : what;
  if (rpe) text += ` @${rpe}`;
  return text || "done";
}

function Sparkline({ points }: { points: [string, number][] }) {
  if (points.length < 2) return null;
  const values = points.map((p) => p[1]);
  const min = Math.min(...values), max = Math.max(...values), span = max - min || 1;
  const d = points.map((p, i) => `${i === 0 ? "M" : "L"}${(i / (points.length - 1)) * 100},${28 - ((p[1] - min) / span) * 24}`).join(" ");
  return (
    <svg className="spark" viewBox="0 0 100 30" preserveAspectRatio="none" aria-hidden="true">
      <path d={d} fill="none" stroke="currentColor" strokeWidth="2" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

export function HistoryView({ units }: { units: Map<string, Unit> }) {
  const sets = loggedSets(units);
  const maxes = estimated1RMs(sets);
  const streak = streakLine(streakNow(units));
  const goals = [...units.entries()]
    .filter(([k, u]) => k.startsWith("goal#") && u.body)
    .map(([, u]) => JSON.parse(u.body!) as Goal)
    .filter((g) => g.status === "active");
  const lifts = Object.entries(maxes).sort((a, b) => b[1] - a[1]).slice(0, 6);
  const days = [...units.entries()]
    .filter(([k, u]) => k.startsWith("log#") && u.body)
    .map(([k, u]) => ({ key: k.slice(4), rows: (JSON.parse(u.body!) as LogRow[]).filter((r) => r.kind === "workout") }))
    .filter((d) => d.rows.length)
    .sort((a, b) => (a.key < b.key ? 1 : -1));
  const title = (key: string) => {
    const body = units.get(`plan#${key}`)?.body;
    return body ? (JSON.parse(body) as PlanRow[]).find((r) => r.slot)?.slot : undefined;
  };
  const goalCurrent = (g: Goal) => {
    const [slug, metric] = g.metric.split(".");
    if (metric === "1rm_lb" && maxes[slug]) return `${round(maxes[slug])} ${g.unit}`;
    return undefined;
  };
  const goalName = (g: Goal) => {
    const [slug, metric] = g.metric.split(".");
    if (metric === "1rm_lb") return `${name(slug)} ${g.target} ${g.unit}`;
    if (metric === "reps") return `${g.target} ${name(slug).toLowerCase()}`;
    if (g.metric === "weight_lb") return `Body weight ${g.target} lb`;
    return `${g.metric.replace(/_/g, " ")} ${g.target}`;
  };

  if (!days.length && !goals.length) {
    return <div className="empty"><h2>No workouts logged yet</h2><p className="muted">Sessions show up here as they're logged in the app.</p></div>;
  }
  return (
    <>
      {streak && <p className="streak">{streak}</p>}
      {(goals.length > 0 || lifts.length > 0) && (
        <section className="progress">
          {goals.map((g, i) => (
            <div className="card" key={`g${i}`}>
              <span className="eyebrow">Goal{g.deadline ? ` · by ${dayFormat.format(new Date(g.deadline * 1000))}` : ""}</span>
              <strong>{goalName(g)}</strong>
              {goalCurrent(g) && <span className="muted">Now {goalCurrent(g)} estimated</span>}
            </div>
          ))}
          {lifts.map(([slug, best]) => {
            const trend = estimated1RMTrend(sets, slug);
            const gain = trend.length > 1 ? best - trend[0][1] : 0;
            return (
              <div className="card" key={slug}>
                <span className="eyebrow">{name(slug)}</span>
                <strong>{round(best)} lb</strong>
                <span className="muted">estimated max{gain >= 1 ? ` · +${round(gain)} lb` : ""}</span>
                <Sparkline points={trend} />
              </div>
            );
          })}
        </section>
      )}
      <ol className="days history">
        {days.map((day) => {
          const byExercise = new Map<string, LogRow[]>();
          for (const row of [...day.rows].sort((a, b) => a.at - b.at)) {
            byExercise.set(row.template ?? "", [...(byExercise.get(row.template ?? "") ?? []), row]);
          }
          const notes = day.rows.map((r) => r.note).filter(Boolean);
          return (
            <li className="day" key={day.key}>
              <div className="date"><span>{dayFormat.format(parse(day.key))}</span></div>
              <div className="session">
                <h3>{title(day.key) ?? "Workout"}</h3>
                <ul>
                  {[...byExercise].map(([slug, rows]) => (
                    <li key={slug}>
                      <span>{name(slug)}</span>
                      <span className="muted">{rows.map(setText).join(", ")}</span>
                    </li>
                  ))}
                </ul>
                {notes.length > 0 && <p className="note">“{[...new Set(notes)].join(" ")}”</p>}
              </div>
            </li>
          );
        })}
      </ol>
    </>
  );
}
