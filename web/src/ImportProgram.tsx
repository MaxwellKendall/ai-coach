import { useState } from "react";
import type { Config } from "./auth";
import { dayKey, weekStart } from "./program";
import { applyImport, importProgram, type ImportedProgram, type ImportSource, type Person } from "./sync";
import { isWorkbook, tabsOf, type Tab } from "./workbook";

// FIT-290: a coach brings a client's existing program over: paste the cells from Excel or Google Sheets, or pick a
// CSV. FIT-291: or a PDF, or a Google Sheet's link. FIT-292: or an .xlsx, one tab at a time. Claude reads it on the server (importProgram.ts) into the weeks it becomes, with the plan checks, and nothing
// is saved until the coach says so. After that, every week is theirs to change in the program editor.

const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);

/** A PDF's bytes as base64, as importProgram takes it. */
const base64 = (file: File) => new Promise<string>((done, fail) => {
  const reader = new FileReader();
  reader.onload = () => done(String(reader.result).split(",")[1] ?? "");
  reader.onerror = () => fail(reader.error);
  reader.readAsDataURL(file);
});

/** What's been given, in the order the server reads it: a sheet link, a PDF, or the pasted text. */
export function sourceOf(text: string, sheet: string, pdf?: { name: string; data: string }): ImportSource | undefined {
  if (sheet.trim()) return { sheet: sheet.trim() };
  if (pdf) return { pdf: pdf.data };
  return text.trim() ? { text } : undefined;
}

/** "Proposal <id> — reason" first, then the days; the id is the server's business. */
export const previewLines = (preview: string) => preview.split("\n").slice(1).join("\n").trim();

export function ImportProgram({ config, client, onDone, onCancel }: {
  config: Config; client: Person; onDone: (message: string) => void; onCancel: () => void;
}) {
  const name = client.name ?? "your client";
  const [text, setText] = useState("");
  const [sheet, setSheet] = useState("");
  const [pdf, setPdf] = useState<{ name: string; data: string }>();
  const [tabs, setTabs] = useState<Tab[]>([]);
  const [start, setStart] = useState(dayKey(addDays(weekStart(new Date()), 8))); // next Monday
  const [busy, setBusy] = useState<"reading" | "saving">();
  const [read, setRead] = useState<ImportedProgram>();
  const [error, setError] = useState<string>();

  const run = (step: "reading" | "saving", work: () => Promise<void>) => async () => {
    setBusy(step);
    setError(undefined);
    try { await work(); } catch (e) { setError((e as Error).message); } finally { setBusy(undefined); }
  };
  const source = sourceOf(text, sheet, pdf);
  const readIt = run("reading", async () => setRead(await importProgram(config, client.uid, source!, start)));
  const save = run("saving", async () => {
    const days = await applyImport(config, client.uid, read!.id);
    onDone(`Imported ${days} ${days === 1 ? "day" : "days"} into ${name}'s program. It shows on their phone at its next sync.`);
  });
  const pickFile = async (file?: File) => {
    if (!file) return;
    setTabs([]);
    if (file.type === "application/pdf" || file.name.toLowerCase().endsWith(".pdf")) return setPdf({ name: file.name, data: await base64(file) });
    setPdf(undefined);
    if (!isWorkbook(file)) return setText(await file.text());
    try {
      const read = await tabsOf(await file.arrayBuffer());
      if (!read.length) return setError("That workbook has nothing in it.");
      setTabs(read);
      setText(read[0].text);
    } catch {
      setError("That file couldn't be read as a spreadsheet. Try saving it as .xlsx, or paste the cells.");
    }
  };

  return (
    <>
      <header className="page">
        <p className="eyebrow">Import a program</p>
        <h1>{name}</h1>
        <p className="lede">Paste the cells from your spreadsheet, pick an Excel, CSV or PDF file, or give a Google Sheet's link. You'll see every day it becomes before anything is saved.</p>
      </header>
      {!read ? (
        <div className="form">
          <label className="wide">The program
            <textarea rows={12} value={text} placeholder={"Week 1\tMonday\tBack Squat\t4 x 5\t225\n…"} onChange={(e) => setText(e.target.value)} />
          </label>
          <label>Or an Excel, CSV or PDF file <input type="file" accept=".xlsx,.xlsm,.xls,.csv,.pdf,text/csv,text/plain,application/pdf" onChange={(e) => pickFile(e.target.files?.[0])} />
            {pdf && <span className="muted">{pdf.name}</span>}</label>
          {tabs.length > 1 && (
            <label>Which tab <select value={tabs.findIndex((t) => t.text === text)} onChange={(e) => setText(tabs[Number(e.target.value)].text)}>
              {tabs.map((tab, i) => <option key={tab.name} value={i}>{tab.name}</option>)}
            </select></label>
          )}
          <label>Or a Google Sheet's link <input type="url" value={sheet} placeholder="https://docs.google.com/spreadsheets/d/…" onChange={(e) => setSheet(e.target.value)} /></label>
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
          <button className="button primary" disabled={!!busy || !source} onClick={readIt}>{busy === "reading" ? "Reading…" : "Read the program"}</button>
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
