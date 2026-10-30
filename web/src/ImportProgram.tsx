import { useState } from "react";
import type { Config } from "./auth";
import { dayKey, weekStart } from "./program";
import { applyImport, importProgram, type ImportedProgram, type Person } from "./sync";

// FIT-290: a coach brings a client's existing program over: paste the cells from Excel or Google Sheets, or pick a
// CSV. Claude reads it on the server (importProgram.ts) into the weeks it becomes, with the plan checks, and nothing
// is saved until the coach says so. After that, every week is theirs to change in the program editor.

const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

/** "Proposal <id> — reason" first, then the days; the id is the server's business. */
export const previewLines = (preview: string) => preview.split("\n").slice(1).join("\n").trim();

export function ImportProgram({ config, client, onDone, onCancel }: {
  config: Config; client: Person; onDone: (message: string) => void; onCancel: () => void;
}) {
  const name = client.name ?? "your client";
  const [text, setText] = useState("");
  const [start, setStart] = useState(dayKey(addDays(weekStart(new Date()), 8))); // next Monday
  const [busy, setBusy] = useState<"reading" | "saving">();
  const [read, setRead] = useState<ImportedProgram>();
  const [error, setError] = useState<string>();

  const run = (step: "reading" | "saving", work: () => Promise<void>) => async () => {
    setBusy(step);
    setError(undefined);
    try { await work(); } catch (e) { setError((e as Error).message); } finally { setBusy(undefined); }
  };
  const readIt = run("reading", async () => setRead(await importProgram(config, client.uid, text, start)));
  const save = run("saving", async () => {
    const days = await applyImport(config, client.uid, read!.id);
    onDone(`Imported ${days} ${days === 1 ? "day" : "days"} into ${name}'s program. It shows on their phone at its next sync.`);
  });
  const pickFile = async (file?: File) => { if (file) setText(await file.text()); };

  return (
    <>
      <header className="page">
        <p className="eyebrow">Import a program</p>
        <h1>{name}</h1>
        <p className="lede">Paste the cells from your spreadsheet, or pick a CSV. You'll see every day it becomes before anything is saved.</p>
      </header>
      {!read ? (
        <div className="form">
          <label className="wide">The program
            <textarea rows={12} value={text} placeholder={"Week 1\tMonday\tBack Squat\t4 x 5\t225\n…"} onChange={(e) => setText(e.target.value)} />
          </label>
          <label>Or a CSV file <input type="file" accept=".csv,text/csv,text/plain" onChange={(e) => pickFile(e.target.files?.[0])} /></label>
          <label>Week 1 starts <input type="date" value={start} min={dayKey(new Date())} onChange={(e) => setStart(e.target.value)} /></label>
        </div>
      ) : (
        <div className="import-preview">
          <pre>{previewLines(read.preview)}</pre>
          {read.added.length > 0 && <p className="muted">New to {name}'s exercises: {read.added.join(", ")}.</p>}
        </div>
      )}
      {error && <p className="error" role="alert">{error}</p>}
      <div className="actions">
        {!read ? (
          <button className="button primary" disabled={!!busy || !text.trim()} onClick={readIt}>{busy === "reading" ? "Reading…" : "Read the program"}</button>
        ) : (
          <>
            <button className="button primary" disabled={!!busy} onClick={save}>{busy === "saving" ? "Saving…" : `Save ${read.days} ${read.days === 1 ? "day" : "days"} to ${name}'s program`}</button>
            <button className="button" disabled={!!busy} onClick={() => setRead(undefined)}>Change the paste</button>
          </>
        )}
        <button className="link" onClick={onCancel}>Cancel</button>
      </div>
    </>
  );
}
