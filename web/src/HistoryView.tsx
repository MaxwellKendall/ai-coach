import catalog from "./catalog.json";
import { sessionNote } from "./corrections";
import { estimated1RMs, estimated1RMTrend, loggedSets, streakLine, streakNow } from "./progress";
import { useState } from "react";
import { SessionEditor } from "./SessionEditor";
import type { Config } from "./auth";
import { deleteComment, editComment, pushLog, unitOf, type Comment, type LogRow, type PlanRow, type Unit } from "./sync";

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

/** FIT-200: what a page lets its viewer correct; each saves to the account and updates the page's units. */
export type Corrections = {
  /** A day's logged rows, all of them (meals and sleep too), as they should be now. */
  saveDay: (day: string, rows: LogRow[]) => Promise<void>;
  editComment: (comment: Comment, text: string) => Promise<void>;
  deleteComment: (comment: Comment) => Promise<void>;
};

/** The corrections for an account's history page: mine, or a client's (uid) as their coach. Last edit wins. */
export function corrections(config: Config, uid: string | undefined, setUnits: (f: (u?: Map<string, Unit>) => Map<string, Unit> | undefined) => void,
                            setThread: (f: (t: Comment[]) => Comment[]) => void): Corrections {
  const same = (a: Comment) => (b: Comment) => a.day === b.day && a.at === b.at && a.by === b.by;
  return {
    saveDay: async (day, rows) => {
      if (!(await pushLog(config, day, rows, uid))) throw new Error("This day changed on the phone since you opened it. Reload to see it, then correct it again.");
      setUnits((u) => u && new Map(u).set(`log#${day}`, unitOf(`log#${day}`, rows)));
    },
    editComment: async (comment, text) => {
      const edited = await editComment(config, comment, text, uid);
      setThread((t) => t.map((c) => (same(comment)(c) ? edited : c)));
    },
    deleteComment: async (comment) => {
      await deleteComment(config, comment, uid);
      setThread((t) => t.filter((c) => !same(comment)(c)));
    },
  };
}

/** FIT-200: one of my replies, which I can change or delete. */
function MyComment({ comment, corrections }: { comment: Comment; corrections?: Corrections }) {
  const [text, setText] = useState<string>();
  const [error, setError] = useState<string>();
  const run = async (work: () => Promise<void>) => {
    setError(undefined);
    try {
      await work();
      setText(undefined);
    } catch (e) {
      setError((e as Error).message);
    }
  };
  if (text !== undefined && corrections) {
    return (
      <div className="reply">
        <textarea autoFocus rows={2} maxLength={1000} value={text} onChange={(e) => setText(e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Escape") setText(undefined); }} />
        <div>
          <button className="button primary" disabled={!text.trim()} onClick={() => run(() => corrections.editComment(comment, text))}>Save</button>
          <button className="link" onClick={() => setText(undefined)}>Cancel</button>
        </div>
        {error && <p className="error">{error}</p>}
      </div>
    );
  }
  return (
    <p className="mine">
      <strong>You</strong> {comment.text}
      {corrections && (
        <span className="tools-inline">
          <button className="link" onClick={() => setText(comment.text)}>Edit</button>
          <button className="link" onClick={() => confirm("Delete this reply?") && run(() => corrections.deleteComment(comment))}>Delete</button>
        </span>
      )}
      {error && <span className="error"> {error}</span>}
    </p>
  );
}

/** FIT-132: a session's thread, and a reply box when replying is allowed. */
function Thread({ day, comments, me, onReply, corrections }: {
  day: string; comments: Comment[]; me?: string; onReply?: (day: string, text: string) => Promise<void>; corrections?: Corrections;
}) {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string>();
  const send = async () => {
    if (!onReply || !text.trim()) return;
    setSending(true);
    setError(undefined);
    try {
      await onReply(day, text);
      setText("");
      setOpen(false);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSending(false);
    }
  };
  return (
    <div className="thread">
      {comments.map((c) => c.by === me ? <MyComment key={c.at + c.by} comment={c} corrections={corrections} /> : (
        <p key={c.at + c.by}><strong>{c.byName ?? "Coach"}</strong> {c.text}</p>
      ))}
      {onReply && (open ? (
        <div className="reply">
          <textarea autoFocus rows={2} maxLength={1000} placeholder="Reply on this session" value={text}
                    onChange={(e) => setText(e.target.value)}
                    onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) send(); if (e.key === "Escape") setOpen(false); }} />
          <div>
            <button className="button primary" disabled={sending || !text.trim()} onClick={send}>{sending ? "Sending…" : "Send"}</button>
            <button className="link" onClick={() => setOpen(false)}>Cancel</button>
          </div>
          {error && <p className="error">{error}</p>}
        </div>
      ) : (
        <button className="add" onClick={() => setOpen(true)}>Reply</button>
      ))}
    </div>
  );
}

export function HistoryView({ units, comments = [], me, onReply, corrections }: {
  units: Map<string, Unit>; comments?: Comment[]; me?: string; onReply?: (day: string, text: string) => Promise<void>; corrections?: Corrections;
}) {
  const [editing, setEditing] = useState<string>();
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
    .map(([k, u]) => {
      const all = JSON.parse(u.body!) as LogRow[];
      return { key: k.slice(4), all, rows: all.filter((r) => r.kind === "workout") };
    })
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
          // The summary row (no exercise) holds the session's note and ratings, not a set.
          for (const row of [...day.rows].filter((r) => r.template).sort((a, b) => a.at - b.at)) {
            byExercise.set(row.template!, [...(byExercise.get(row.template!) ?? []), row]);
          }
          const note = sessionNote(day.rows, title(day.key));
          const thread = <Thread day={day.key} comments={comments.filter((c) => c.day === day.key)} me={me} onReply={onReply} corrections={corrections} />;
          if (editing === day.key && corrections) {
            return (
              <li className="day" key={day.key}>
                <div className="date"><span>{dayFormat.format(parse(day.key))}</span></div>
                <div className="session">
                  <h3>{title(day.key) ?? "Workout"}</h3>
                  <SessionEditor rows={day.all} title={title(day.key)} name={name} onCancel={() => setEditing(undefined)}
                                 onSave={async (rows) => { await corrections.saveDay(day.key, rows); setEditing(undefined); }} />
                  {thread}
                </div>
              </li>
            );
          }
          return (
            <li className="day" key={day.key}>
              <div className="date"><span>{dayFormat.format(parse(day.key))}</span></div>
              <div className="session">
                <h3>{title(day.key) ?? "Workout"}
                  {corrections && <button className="copy" onClick={() => setEditing(day.key)}>Edit</button>}</h3>
                <ul>
                  {[...byExercise].map(([slug, rows]) => (
                    <li key={slug}>
                      <span>{name(slug)}</span>
                      <span className="muted">{rows.map(setText).join(", ")}</span>
                    </li>
                  ))}
                </ul>
                {note && <p className="note">“{note}”</p>}
                {thread}
              </div>
            </li>
          );
        })}
      </ol>
    </>
  );
}
