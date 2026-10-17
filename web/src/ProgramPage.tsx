import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Config, User } from "./auth";
import catalog from "./catalog.json";
import { addLine, editLine, editLines, editOf, moveDay, moveLine, removeLine, type Edit, type EditLine } from "./edit";
import { checkDay, checkWeek, type Exercise, type Profile } from "./guard";
import { dayKey, describe, week, weekStart, type Day } from "./program";
import { pullAll, pushDay, type PlanRow, type Unit } from "./sync";

const names = new Map(catalog.map((t) => [t.slug, t.name]));
const exercises = new Map<string, Exercise>(catalog.map((t) => [t.slug, t]));
const weekday = new Intl.DateTimeFormat(undefined, { weekday: "short" });
const monthDay = new Intl.DateTimeFormat(undefined, { month: "long", day: "numeric" });

const rowsOf = (units: Map<string, Unit>, key: string): PlanRow[] => {
  const body = units.get(`plan#${key}`)?.body;
  return body ? JSON.parse(body) : [];
};

/** FIT-128: the program, this week editable in place, earlier weeks to look back on. Each edit syncs as it's made. */
export function ProgramPage({ config, me, empty, uid, heading = "This week" }: {
  config: Config; me: User; empty: React.ReactNode; uid?: string; heading?: string;
}) {
  const [units, setUnits] = useState<Map<string, Unit>>();
  const [error, setError] = useState<string>();
  const [status, setStatus] = useState<string>();

  // Bumped by every edit: a pull that started before an edit would show the old plan, so it's dropped.
  const edits = useRef(0);
  const load = useCallback(() => {
    const at = edits.current;
    return pullAll(config, uid).then((u) => { if (edits.current === at) setUnits(u); }, (e: Error) => setError(e.message));
  }, [config, uid]);
  useEffect(() => {
    load();
    // Back on this tab: the phone may have changed something.
    const onFocus = () => load();
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [load]);

  const save = useCallback(
    async (key: string, rows: PlanRow[]) => {
      const body = rows.length ? JSON.stringify(rows) : null;
      edits.current += 1;
      setUnits((u) => new Map(u).set(`plan#${key}`, { key: `plan#${key}`, updatedAt: new Date().toISOString(), deleted: !body, body }));
      setStatus("Saving…");
      try {
        const kept = await pushDay(config, key, rows, uid);
        const phone = uid ? "their phone" : "your phone";
        setStatus(kept ? `Saved. It's on ${phone} the next time the app is open.` : `Changed on ${phone} in the meantime; showing that.`);
        if (!kept) await load();
      } catch (e) {
        setStatus(`Couldn't save: ${(e as Error).message}`);
        await load();
      }
    },
    [config, load, uid],
  );

  const today = new Date();
  const days = useMemo(() => (units ? week(units, today, names) : []), [units]);
  const earlier = useMemo(() => {
    if (!units) return [];
    const thisWeek = weekStart(today).getTime();
    const starts = new Set<number>();
    for (const [key, unit] of units) {
      if (!key.startsWith("plan#") || unit.deleted) continue;
      const [y, mo, d] = key.slice(5).split("-").map(Number);
      const start = weekStart(new Date(y, mo - 1, d)).getTime();
      if (start < thisWeek) starts.add(start);
    }
    return [...starts].sort((a, b) => b - a).map((t) => new Date(t));
  }, [units]);

  if (error) return <p className="error" role="alert">Couldn't load your program: {error}</p>;
  if (!units) return <p className="muted">Loading your program…</p>;
  if (![...units.values()].some((u) => u.key.startsWith("plan#") && !u.deleted)) return <>{empty}</>;

  const todayKey = dayKey(today);
  // The picker offers what the profile's equipment allows, as the app's catalog does.
  const profileBody = units.get("profile")?.body;
  const profile: Profile | undefined = profileBody ? JSON.parse(profileBody) : undefined;
  // Without a profile (it hasn't synced), nothing is known to be missing, so the whole catalog.
  const equipment = profile?.equipment ? new Set(profile.equipment) : undefined;
  const weekWarning = checkWeek(days.map((d) => rowsOf(units, d.key)), profile);
  const editable = (day: Day) => day.key >= todayKey && !day.done;
  // FIT-128: a session dragged onto a rest day moves there (both days sync).
  const move = async (from: Day, to: Day) => {
    const rows = rowsOf(units, from.key);
    if (from.key === to.key || !rows.length || rowsOf(units, to.key).some((r) => r.kind === "workout")) return;
    await save(to.key, moveDay(rows, from.date.getTime() / 1000, to.date.getTime() / 1000));
    await save(from.key, []);
  };
  return (
    <>
      <header className="page">
        <p className="eyebrow">Week of {monthDay.format(days[0].date)}</p>
        <h1>{heading}</h1>
        {status && <p className="status" role="status">{status}</p>}
        {weekWarning && <p className="warning">{weekWarning}</p>}
      </header>
      <ol className="days">
        {days.map((day) => (
          <DayCard key={day.key} day={day} today={day.key === todayKey} editable={editable(day)}
                   rows={rowsOf(units, day.key)} equipment={equipment} onSave={(rows) => save(day.key, rows)}
                   warnings={editable(day) ? checkDay(rowsOf(units, day.key), profile, exercises) : []}
                   onDrop={(fromKey) => { const from = days.find((d) => d.key === fromKey); if (from && editable(from)) move(from, day); }} />
        ))}
      </ol>
      {earlier.length > 0 && (
        <section className="earlier">
          <h2>Earlier weeks</h2>
          {earlier.map((start) => (
            <details key={start.getTime()}>
              <summary>Week of {monthDay.format(start)}</summary>
              <ol className="days">
                {week(units, start, names).map((day) => (
                  <DayCard key={day.key} day={day} today={false} editable={false} rows={[]} equipment={equipment} onSave={() => {}} />
                ))}
              </ol>
            </details>
          ))}
        </section>
      )}
    </>
  );
}

function DayCard({ day, today, editable, rows, equipment, onSave, warnings = [], onDrop }: {
  day: Day; today: boolean; editable: boolean; rows: PlanRow[]; equipment?: Set<string>; onSave: (rows: PlanRow[]) => void;
  warnings?: string[]; onDrop?: (fromKey: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [over, setOver] = useState(false);
  const lines = editLines(rows);
  const dayStart = day.date.getTime() / 1000;
  const empty = editable ? lines.length === 0 : day.lines.length === 0;
  return (
    <li className={`day${today ? " today" : ""}${empty ? " rest" : ""}${over ? " drop" : ""}`}
        onDragOver={(e) => { if (editable && empty && onDrop) { e.preventDefault(); setOver(true); } }}
        onDragLeave={() => setOver(false)}
        onDrop={(e) => { setOver(false); onDrop?.(e.dataTransfer.getData("text/x-day")); }}>
      <div className="date">
        <span>{weekday.format(day.date)}</span>
        <strong>{day.date.getDate()}</strong>
      </div>
      <div className="session">
        {!empty && (
          <h3 draggable={editable} title={editable ? "Drag to a rest day to move this session" : undefined}
              className={editable ? "handle" : undefined}
              onDragStart={(e) => { e.dataTransfer.setData("text/x-day", day.key); e.dataTransfer.effectAllowed = "move"; }}>
            {day.title ?? "Workout"}
            {day.done && <span className="done">Done</span>}
          </h3>
        )}
        {empty && !adding && <p className="muted">{day.done ? "Trained" : "Rest"}</p>}
        {editable ? (
          <>
            {lines.length > 0 && (
              <ul className="edit">
                {lines.map((line, i) => (
                  <LineRow key={line.ids[0]} line={line} first={i === 0} last={i === lines.length - 1}
                           onEdit={(edit) => onSave(editLine(rows, line, edit))}
                           onMove={(by) => onSave(moveLine(rows, line, by))}
                           onRemove={() => onSave(removeLine(rows, line))} />
                ))}
              </ul>
            )}
            {warnings.length > 0 && (
              <ul className="warnings">{warnings.map((w) => <li key={w}>{w}</li>)}</ul>
            )}
            {adding ? (
              <ExercisePicker equipment={equipment} onPick={(slug) => { setAdding(false); onSave(addLine(rows, slug, "Workout", dayStart)); }}
                              onCancel={() => setAdding(false)} />
            ) : (
              <button className="add" onClick={() => setAdding(true)}>+ Add exercise</button>
            )}
          </>
        ) : (
          !empty && (
            <ul>
              {day.lines.map((line, i) => (
                <li key={i}>
                  <span>{line.exercise}</span>
                  <span className="muted">{describe(line)}</span>
                </li>
              ))}
            </ul>
          )
        )}
      </div>
    </li>
  );
}

/** A number cell that saves when it loses focus or on Return; empty is "none". */
function NumberCell({ value, label, step = 1, onCommit }: {
  value?: number; label: string; step?: number; onCommit: (v: number | undefined) => void;
}) {
  const [text, setText] = useState(value === undefined ? "" : String(value));
  useEffect(() => setText(value === undefined ? "" : String(value)), [value]);
  const commit = () => {
    const v = text.trim() === "" ? undefined : Number(text);
    if (v !== undefined && (Number.isNaN(v) || v < 0)) return setText(value === undefined ? "" : String(value));
    if (v !== value) onCommit(v);
  };
  return (
    <input className="num" type="number" inputMode="decimal" min={0} step={step} aria-label={label} value={text}
           onChange={(e) => setText(e.target.value)} onBlur={commit}
           onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
  );
}

function LineRow({ line, first, last, onEdit, onMove, onRemove }: {
  line: EditLine; first: boolean; last: boolean; onEdit: (e: Edit) => void; onMove: (by: -1 | 1) => void; onRemove: () => void;
}) {
  const edit = editOf(line);
  const name = (line.template && names.get(line.template)) ?? line.template ?? "Exercise";
  const timed = edit.seconds !== undefined && edit.reps === undefined;
  const perHand = line.targets.some((t) => t.metric === "load_lb_hand");
  const set = (patch: Partial<Edit>) => onEdit({ ...edit, ...patch });
  return (
    <li>
      <span className="name">{name}</span>
      <span className="cells">
        <NumberCell label={`${name} sets`} value={edit.sets} onCommit={(v) => set({ sets: v ?? 1 })} />
        <span className="x">×</span>
        {timed ? (
          <><NumberCell label={`${name} seconds`} value={edit.seconds} step={5} onCommit={(v) => set({ seconds: v })} /><span className="unit">s</span></>
        ) : (
          <NumberCell label={`${name} reps`} value={edit.reps} onCommit={(v) => set({ reps: v })} />
        )}
        <span className="x">@</span>
        <NumberCell label={`${name} load`} value={edit.load} step={5} onCommit={(v) => set({ load: v })} />
        <span className="unit">{perHand ? "lb/hand" : "lb"}</span>
        <span className="x">RPE</span>
        <NumberCell label={`${name} RPE`} value={edit.rpe} step={0.5} onCommit={(v) => set({ rpe: v })} />
      </span>
      <span className="tools">
        <button aria-label={`Move ${name} up`} disabled={first} onClick={() => onMove(-1)}>↑</button>
        <button aria-label={`Move ${name} down`} disabled={last} onClick={() => onMove(1)}>↓</button>
        <button aria-label={`Remove ${name}`} onClick={onRemove}>✕</button>
      </span>
    </li>
  );
}

function ExercisePicker({ equipment, onPick, onCancel }: {
  equipment?: Set<string>; onPick: (slug: string) => void; onCancel: () => void;
}) {
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase();
  const matches = q.length < 2 ? [] : catalog
    .filter((t) => (!equipment || t.equipment.every((e) => equipment.has(e))) && t.name.toLowerCase().includes(q))
    .slice(0, 8);
  return (
    <div className="picker">
      <input autoFocus placeholder="Search exercises" aria-label="Search exercises" value={query}
             onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => {
               if (e.key === "Escape") onCancel();
               if (e.key === "Enter" && matches[0]) onPick(matches[0].slug);
             }} />
      {matches.length > 0 && (
        <ul>
          {matches.map((t) => (
            <li key={t.slug}><button onClick={() => onPick(t.slug)}>{t.name}</button></li>
          ))}
        </ul>
      )}
      <button className="link" onClick={onCancel}>Cancel</button>
    </div>
  );
}
