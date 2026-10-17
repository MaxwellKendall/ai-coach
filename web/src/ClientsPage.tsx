import { useEffect, useState } from "react";
import type { Config, User } from "./auth";
import { HistoryView } from "./HistoryView";
import { ProgramPage } from "./ProgramPage";
import { createClientInvite, myClients, pullAll, removeClient, type Person, type Unit } from "./sync";

// FIT-130: the people you coach. Invite one with a link they open on their iPhone; each client opens on their program
// (the same editor as your own) and their history.

const since = new Intl.DateTimeFormat(undefined, { month: "long", day: "numeric", year: "numeric" });
export const personName = (p: Person) => p.name ?? "Your client";

export function ClientsPage({ config, go }: { config: Config; go: (path: string) => (e?: React.MouseEvent) => void }) {
  const [clients, setClients] = useState<Person[]>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    myClients(config).then(setClients, (e: Error) => setError(e.message));
  }, [config]);

  return (
    <>
      <header className="page">
        <h1>Clients</h1>
        <p className="lede">Write their program, see how their sessions go, and change it as they train.</p>
      </header>
      <InviteBox config={config} />
      {error && <p className="error" role="alert">Couldn't load your clients: {error}</p>}
      {clients && clients.length > 0 && (
        <ul className="clients">
          {clients.map((c) => (
            <li key={c.uid}>
              <a href={`/clients/${c.uid}`} onClick={go(`/clients/${c.uid}`)}>
                <strong>{personName(c)}</strong>
                <span className="muted">Since {since.format(new Date(c.since))}</span>
              </a>
            </li>
          ))}
        </ul>
      )}
      {clients && clients.length === 0 && (
        <p className="muted">No clients yet. When someone accepts your invite in the app, they show up here.</p>
      )}
    </>
  );
}

function InviteBox({ config }: { config: Config }) {
  const [invite, setInvite] = useState<{ url: string }>();
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string>();
  const make = async () => {
    setError(undefined);
    try {
      setInvite(await createClientInvite(config));
      setCopied(false);
    } catch (e) {
      setError((e as Error).message);
    }
  };
  const copy = async () => {
    if (!invite) return;
    try {
      await navigator.clipboard.writeText(invite.url);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };
  return (
    <div className="invite">
      {invite ? (
        <>
          <p><strong>Send this link to your client.</strong> It works once, for 14 days. They open it on their iPhone and allow you to coach them.</p>
          <div className="link-row">
            <input readOnly value={invite.url} aria-label="Invite link" onFocus={(e) => e.target.select()} />
            <button className="button primary" onClick={copy}>{copied ? "Copied" : "Copy link"}</button>
          </div>
          <button className="link" onClick={make}>Make another link</button>
        </>
      ) : (
        <button className="button primary" onClick={make}>Invite a client</button>
      )}
      {error && <p className="error" role="alert">{error}</p>}
    </div>
  );
}

export function ClientPage({ config, me, uid, go }: {
  config: Config; me: User; uid: string; go: (path: string) => (e?: React.MouseEvent) => void;
}) {
  const [client, setClient] = useState<Person | null>();
  const [units, setUnits] = useState<Map<string, Unit>>();
  const [tab, setTab] = useState<"program" | "history">("program");
  const [error, setError] = useState<string>();
  useEffect(() => {
    myClients(config).then((list) => setClient(list.find((c) => c.uid === uid) ?? null), (e: Error) => setError(e.message));
  }, [config, uid]);
  useEffect(() => {
    if (tab === "history" && client) pullAll(config, uid).then(setUnits, (e: Error) => setError(e.message));
  }, [config, uid, tab, client]);

  const remove = async () => {
    if (!client || !confirm(`Stop coaching ${personName(client)}? You won't see their program or training any more.`)) return;
    await removeClient(config, uid);
    go("/clients")();
  };

  if (error) return <p className="error" role="alert">{error}</p>;
  if (client === undefined) return <p className="muted">Loading…</p>;
  if (client === null) {
    return (
      <div className="empty">
        <h2>Not one of your clients</h2>
        <p className="muted">They may have stopped sharing with you.</p>
        <a href="/clients" onClick={go("/clients")}>Back to clients</a>
      </div>
    );
  }
  return (
    <>
      <p className="crumb"><a href="/clients" onClick={go("/clients")}>Clients</a></p>
      <div className="tabs" role="tablist">
        <button role="tab" aria-selected={tab === "program"} onClick={() => setTab("program")}>Program</button>
        <button role="tab" aria-selected={tab === "history"} onClick={() => setTab("history")}>History</button>
      </div>
      {tab === "program" ? (
        <ProgramPage key={uid} config={config} me={me} uid={uid} heading={personName(client)}
                     empty={<div className="empty"><h2>{personName(client)}</h2><p className="muted">Nothing planned yet. Their program shows up here once their app has synced it.</p></div>} />
      ) : (
        <>
          <header className="page"><h1>{personName(client)}</h1></header>
          {units ? <HistoryView units={units} /> : <p className="muted">Loading…</p>}
        </>
      )}
      <p className="danger"><button className="link" onClick={remove}>Stop coaching {personName(client)}</button></p>
    </>
  );
}
