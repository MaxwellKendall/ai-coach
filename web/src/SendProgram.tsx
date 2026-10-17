import { useEffect, useState } from "react";
import type { Config } from "./auth";
import catalog from "./catalog.json";
import { brief, choices, design, request, toWeek, type CatalogEntry } from "./design";
import { checkDay, type Exercise, type Profile } from "./guard";
import { DayCard } from "./ProgramPage";
import { dayKey, lines, weekStart, type Day } from "./program";
import { pullAll, sendProgram, type Person, type PlanRow, type TemplateDay, type Unit } from "./sync";

// FIT-131: a coach writes a program for a client: one week, laid out with the same editor as a program, repeated for
// some weeks from a start day, with a note and, if they like, a few pounds more on the main lifts each week. It goes to
// the client as an offer they start or decline in the app.

const names = new Map(catalog.map((t) => [t.slug, t.name]));
const exercises = new Map<string, Exercise>(catalog.map((t) => [t.slug, t]));
const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
type Week = PlanRow[][]; // by weekday, Sunday first

/** A week's sessions from a plan, by weekday, as the template to start from. */
function weekFrom(units: Map<string, Unit>, start: Date): Week {
  return Array.from({ length: 7 }, (_, i) => {
    const body = units.get(`plan#${dayKey(addDays(start, i))}`)?.body;
    const rows: PlanRow[] = body ? JSON.parse(body) : [];
    return rows.filter((r) => r.kind === "workout").map((r) => ({ ...r, adjustedReason: undefined, pinned: false }));
  });
}

export function SendProgram({ config, client, onSent, onCancel }: {
  config: Config; client: Person; onSent: (message: string) => void; onCancel: () => void;
}) {
  const nextSunday = addDays(weekStart(new Date()), 7);
  const [start, setStart] = useState(dayKey(nextSunday));
  const [weeks, setWeeks] = useState(4);
  const [note, setNote] = useState("");
  const [add, setAdd] = useState(0);
  const [template, setTemplate] = useState<Week>(() => Array.from({ length: 7 }, () => []));
  const [from, setFrom] = useState<"empty" | "theirs" | "mine">("empty");
  const [sending, setSending] = useState(false);
  const [designing, setDesigning] = useState(false);
  const [error, setError] = useState<string>();
  // The client's synced units: their profile and lifts for designing, and for the plan checks.
  const [clientUnits, setClientUnits] = useState<Map<string, Unit>>();
  useEffect(() => {
    pullAll(config, client.uid).then(setClientUnits, () => setClientUnits(new Map()));
  }, [config, client.uid]);
  const profileBody = clientUnits?.get("profile")?.body;
  const profile: Profile | undefined = profileBody ? JSON.parse(profileBody) : undefined;

  useEffect(() => {
    if (from === "empty") return setTemplate(Array.from({ length: 7 }, () => []));
    pullAll(config, from === "theirs" ? client.uid : undefined)
      .then((units) => setTemplate(weekFrom(units, weekStart(new Date()))), (e: Error) => setError(e.message));
  }, [from, config, client.uid]);

  const [y, m, d] = start.split("-").map(Number);
  const firstWeek = weekStart(new Date(y, m - 1, d));
  const days: Day[] = template.map((rows, i) => {
    const date = addDays(firstWeek, i);
    return { date, key: dayKey(date), title: rows.find((r) => r.slot)?.slot, lines: lines(rows, names), done: false };
  });
  const sessions = template.filter((rows) => rows.length).length;
  // A session moved onto a rest day takes its rows there.
  const move = (fromKey: string, to: number) => {
    const fromIndex = days.findIndex((x) => x.key === fromKey);
    if (fromIndex < 0 || fromIndex === to || template[to].length) return;
    const next = [...template];
    next[to] = next[fromIndex].map((r) => ({ ...r, at: r.at + (to - fromIndex) * 86_400 }));
    next[fromIndex] = [];
    setTemplate(next);
  };

  // FIT-141: Claude Haiku lays out the week from the client's profile, goals and lifts, and the note.
  const designWeek = async () => {
    if (!clientUnits) return;
    setDesigning(true);
    setError(undefined);
    try {
      const about = brief(clientUnits, names);
      const menu = choices(catalog as CatalogEntry[], about.profile);
      const answer = await design(config, request(about.text, menu, note));
      const week = toWeek(answer, menu, firstWeek);
      if (!week.some((d) => d.length)) throw new Error("Claude didn't plan any sessions. Add a note on what you want and try again.");
      setTemplate(week);
    } catch (e) {
      setError(`Couldn't design the week: ${(e as Error).message}`);
    } finally {
      setDesigning(false);
    }
  };

  const send = async () => {
    setSending(true);
    setError(undefined);
    const payload: TemplateDay[] = template.flatMap((rows, weekday) => rows.length ? [{
      weekday,
      slot: rows.find((r) => r.slot && r.slot !== "Workout")?.slot ?? `${weekdays[weekday]} session`,
      rows: [...rows].sort((a, b) => a.at - b.at).map((r) => ({
        template: r.template ?? "", targets: r.targets, note: r.note, ...(r.group != null ? { group: r.group } : {}), main: r.main,
      })),
    }] : []);
    try {
      await sendProgram(config, client.uid, start, weeks, note, payload, add);
      onSent(`Sent. ${client.name ?? "Your client"} can start it from the app.`);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSending(false);
    }
  };

  return (
    <>
      <header className="page">
        <p className="eyebrow">New program</p>
        <h1>For {client.name ?? "your client"}</h1>
        <p className="lede">Lay out one week. It repeats for every week of the program, and you can change any week after they start.</p>
      </header>
      <div className="form">
        <label>Starts <input type="date" value={start} min={dayKey(new Date())} onChange={(e) => setStart(e.target.value)} /></label>
        <label>Weeks <input type="number" min={1} max={16} value={weeks} onChange={(e) => setWeeks(Math.max(1, Math.min(16, Number(e.target.value) || 1)))} /></label>
        <label>Main lifts each week <span className="with-unit"><input type="number" min={0} max={20} step={2.5} value={add}
          onChange={(e) => setAdd(Math.max(0, Math.min(20, Number(e.target.value) || 0)))} /> lb</span></label>
        <label>Start from
          <select value={from} onChange={(e) => setFrom(e.target.value as typeof from)}>
            <option value="empty">An empty week</option>
            <option value="theirs">Their week now</option>
            <option value="mine">My week now</option>
          </select>
        </label>
        <div className="wide design">
          <button className="button" disabled={designing || !clientUnits} onClick={designWeek}>
            {designing ? "Designing…" : "Design it for me"}
          </button>
          <span className="muted">Claude lays out the week from their profile, goals and lifts, and your note. You can change anything after.</span>
        </div>
        <label className="wide">Note for them <textarea rows={2} maxLength={500} value={note} placeholder="What this block is for"
          onChange={(e) => setNote(e.target.value)} /></label>
      </div>
      <ol className="days">
        {days.map((day, i) => (
          <DayCard key={day.key} day={day} today={false} editable rows={template[i]}
                   equipment={profile?.equipment ? new Set(profile.equipment) : undefined}
                   warnings={checkDay(template[i], profile, exercises)}
                   onSave={(rows) => setTemplate((t) => t.map((r, j) => (j === i ? rows.map((x) => ({ ...x, slot: x.slot === "Workout" ? weekdays[i] : x.slot })) : r)))}
                   onDrop={(fromKey) => move(fromKey, i)} />
        ))}
      </ol>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="actions">
        <button className="button primary" disabled={sending || sessions === 0} onClick={send}>
          {sending ? "Sending…" : `Send ${weeks}-week program`}
        </button>
        <button className="link" onClick={onCancel}>Cancel</button>
        <span className="muted">{sessions} {sessions === 1 ? "session" : "sessions"} a week</span>
      </div>
    </>
  );
}
