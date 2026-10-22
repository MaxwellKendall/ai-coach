import { useState } from "react";
import { clearSession, fixSet, isSet, removeSet, sessionNote, setFields, withNote, type SetFix } from "./corrections";
import type { LogRow } from "./sync";

// FIT-200: correct a logged session in place: each set's weight, reps (or seconds) and RPE, the note, or clear it all.

const number = (text: string) => (text.trim() === "" ? null : Number(text));

export function SessionEditor({ rows, title, name, onSave, onCancel }: {
  rows: LogRow[]; title?: string; name: (slug?: string) => string;
  onSave: (rows: LogRow[]) => Promise<void>; onCancel: () => void;
}) {
  const [draft, setDraft] = useState(rows);
  const [note, setNote] = useState(() => sessionNote(rows, title));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();
  const save = async (next: LogRow[]) => {
    setSaving(true);
    setError(undefined);
    try {
      await onSave(next);
    } catch (e) {
      setError((e as Error).message);
      setSaving(false);
    }
  };
  const fix = (id: string, change: SetFix) => setDraft((d) => fixSet(d, id, change));
  const sets = draft.filter(isSet).sort((a, b) => a.at - b.at);
  const clear = () => {
    if (confirm(`Clear ${title ?? "this session"}? Every set and its note go, on the phone too.`)) save(clearSession(rows));
  };

  return (
    <div className="correct">
      <ul>
        {sets.map((row) => {
          const f = setFields(row);
          return (
            <li key={row.id}>
              <span className="what">{name(row.template)}</span>
              <label><input type="number" inputMode="decimal" min={0} step={2.5} aria-label="Weight" defaultValue={f.load ?? ""}
                            onChange={(e) => fix(row.id, { load: number(e.target.value) })} /> {f.loadUnit}</label>
              <label><input type="number" inputMode="numeric" min={0} aria-label={f.timed ? "Seconds" : "Reps"} defaultValue={f.count ?? ""}
                            onChange={(e) => fix(row.id, f.timed ? { seconds: number(e.target.value) } : { reps: number(e.target.value) })} /> {f.timed ? "s" : "reps"}</label>
              <label>RPE <input type="number" inputMode="decimal" min={1} max={10} step={0.5} aria-label="RPE" defaultValue={f.rpe ?? ""}
                                onChange={(e) => fix(row.id, { rpe: number(e.target.value) })} /></label>
              <button className="remove" aria-label={`Remove this set of ${name(row.template)}`} onClick={() => setDraft((d) => removeSet(d, row.id))}>×</button>
            </li>
          );
        })}
      </ul>
      <label className="note-edit">Their note
        <textarea rows={2} maxLength={1000} value={note} placeholder="No note" onChange={(e) => setNote(e.target.value)} />
      </label>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="actions">
        <button className="button primary" disabled={saving} onClick={() => save(withNote(draft, note, title))}>{saving ? "Saving…" : "Save"}</button>
        <button className="link" disabled={saving} onClick={onCancel}>Cancel</button>
        <button className="link danger-link" disabled={saving} onClick={clear}>Clear session</button>
      </div>
    </div>
  );
}
