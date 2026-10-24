import { useEffect, useState } from "react";
import type { Config, User } from "./auth";
import { coachPlan, hasPlan, needsPlan } from "./billing";
import { corrections, HistoryView } from "./HistoryView";
import { href } from "./paths";
import { ProgramPage } from "./ProgramPage";
import catalog from "./catalog.json";
import { SendProgram } from "./SendProgram";
import { comments as loadComments, createClientInvite, myClients, postComment, programOffers, pullAll, removeClient, type Comment, type Offer, type Person, type Unit } from "./sync";
import { byNeed, triage, type Triage } from "./triage";

const names = new Map(catalog.map((t) => [t.slug, t.name]));
const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric" });
const parseDay = (key: string) => {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
};

// FIT-130: the people you coach. Invite one with a link they open on their iPhone; each client opens on their program
// (the same editor as your own) and their history.

const since = new Intl.DateTimeFormat(undefined, { month: "long", day: "numeric", year: "numeric" });
export const personName = (p: Person) => p.name ?? "Your client";

type Go = (path: string, replace?: boolean) => (e?: React.MouseEvent) => void;
const toBilling = (go: Go) => go("/billing?coaching=1", true)();

/**
 * FIT-148: coaching needs the coach plan. FIT-240: without it a coach still sees and coaches their sample client; the
 * server answers only with that (coach.ts myClients), and sends the coach to Billing when there's none.
 */
function usePaid(config: Config) {
  const [paid, setPaid] = useState<boolean>();
  useEffect(() => {
    coachPlan(config).then((plan) => setPaid(hasPlan(plan)), () => setPaid(true));
  }, [config]);
  return paid;
}

export function ClientsPage({ config, me, go }: { config: Config; me: User; go: Go }) {
  const paid = usePaid(config);
  const ready = paid !== undefined;
  const [clients, setClients] = useState<(Person & { triage?: Triage })[]>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    if (!ready) return;
    myClients(config).then((list) => {
      setClients(list);
      // FIT-132: each client's week and what needs the coach, from their synced units and the session threads.
      Promise.all(list.map(async (c): Promise<Person & { triage?: Triage }> => {
        try {
          const [units, thread] = await Promise.all([pullAll(config, c.uid), loadComments(config, c.uid)]);
          return { ...c, triage: triage(units, thread, names, me.uid) };
        } catch {
          return c;
        }
      })).then((withTriage) => setClients(byNeed(withTriage)));
    }, (e: Error) => (needsPlan(e) ? toBilling(go) : setError(e.message)));
  }, [config, me.uid, ready]);

  if (!ready) return <p className="muted">Loading…</p>;

  return (
    <>
      <header className="page">
        <h1>Clients</h1>
        <p className="lede">Write their program, see how their sessions go, and change it as they train.</p>
      </header>
      {paid ? <InviteBox config={config} /> : (
        <div className="invite">
          <p>
            <strong>Try coaching on your sample client.</strong> Plan their week in Claude and apply it, or open them here.
            Inviting your own clients needs the coach plan.
          </p>
          <a className="button primary" href={href("/billing?coaching=1")} onClick={go("/billing?coaching=1")}>Start the coach plan</a>
        </div>
      )}
      {error && <p className="error" role="alert">Couldn't load your clients: {error}</p>}
      {clients && clients.length > 0 && (
        <ul className="clients">
          {clients.map((c) => (
            <li key={c.uid}>
              <a href={href(`/clients/${c.uid}`)} onClick={go(`/clients/${c.uid}`)}>
                <span className="who">
                  <strong>{personName(c)}</strong>
                  {c.triage ? (
                    <span className="muted">
                      {c.triage.planned ? `${c.triage.done} of ${c.triage.planned} this week` : "Nothing planned this week"}
                      {c.triage.streak && c.triage.streak >= 2 ? ` · ${c.triage.streak} weeks in a row` : ""}
                      {c.triage.lastSession ? ` · last ${dayFormat.format(parseDay(c.triage.lastSession))}` : ""}
                    </span>
                  ) : (
                    <span className="muted">Since {since.format(new Date(c.since))}</span>
                  )}
                </span>
                {c.triage && c.triage.flags.length > 0 && (
                  <ul className="flags">
                    {c.triage.flags.map((f) => <li key={f.text} className={f.kind}>{f.text}</li>)}
                  </ul>
                )}
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
  const [invite, setInvite] = useState<{ url: string; code: string }>();
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
          {/* FIT-234: a code short enough to say, for a client who already has the app. */}
          <p className="muted">Or they open Barbrabell and enter the code <strong className="code">{invite.code}</strong>.</p>
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
  config: Config; me: User; uid: string; go: Go;
}) {
  const ready = true; // FIT-240: the server says when this client needs the plan (needsPlan below)
  const [client, setClient] = useState<Person | null>();
  const [units, setUnits] = useState<Map<string, Unit>>();
  const [thread, setThread] = useState<Comment[]>([]);
  const [tab, setTab] = useState<"program" | "history">("program");
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState<Offer[]>([]);
  const [message, setMessage] = useState<string>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    if (!ready) return;
    myClients(config).then((list) => setClient(list.find((c) => c.uid === uid) ?? null), (e: Error) => (needsPlan(e) ? toBilling(go) : setError(e.message)));
  }, [config, uid, ready]);
  // FIT-131: the programs sent to this client, and what they said.
  useEffect(() => {
    if (client) programOffers(config, uid).then(setSent, () => setSent([]));
  }, [config, uid, client, sending]);
  useEffect(() => {
    if (tab === "history" && client) {
      pullAll(config, uid).then(setUnits, (e: Error) => setError(e.message));
      loadComments(config, uid).then(setThread, () => setThread([]));
    }
  }, [config, uid, tab, client]);

  const remove = async () => {
    if (!client || !confirm(`Stop coaching ${personName(client)}? You won't see their program or training any more.`)) return;
    await removeClient(config, uid);
    go("/clients")();
  };

  if (error) return <p className="error" role="alert">{error}</p>;
  if (!ready || client === undefined) return <p className="muted">Loading…</p>;
  if (client === null) {
    return (
      <div className="empty">
        <h2>Not one of your clients</h2>
        <p className="muted">They may have stopped sharing with you.</p>
        <a href={href("/clients")} onClick={go("/clients")}>Back to clients</a>
      </div>
    );
  }
  if (sending) {
    return (
      <SendProgram config={config} client={client} onCancel={() => setSending(false)}
                   onSent={(text) => { setMessage(text); setSending(false); }} />
    );
  }
  const shortDate = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
  const startOf = (o: Offer) => { const [y, m, d] = o.start.split("-").map(Number); return shortDate.format(new Date(y, m - 1, d)); };
  return (
    <>
      <p className="crumb"><a href={href("/clients")} onClick={go("/clients")}>Clients</a></p>
      <div className="actions top">
        <button className="button primary" onClick={() => { setMessage(undefined); setSending(true); }}>Send a program</button>
        {message && <span className="status">{message}</span>}
      </div>
      {sent.length > 0 && (
        <ul className="offers">
          {sent.slice(0, 5).map((o) => (
            <li key={o.id}>
              <span>{o.weeks}-week program from {startOf(o)}{o.note ? ` · “${o.note}”` : ""}</span>
              <span className={o.status}>{o.status === "sent" ? "Waiting for them" : o.status === "started" ? "Started" : "Declined"}</span>
            </li>
          ))}
        </ul>
      )}
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
          {units ? (
            <HistoryView units={units} comments={thread} me={me.uid} corrections={corrections(config, uid, setUnits, setThread)}
                         onReply={async (day, text) => { const c = await postComment(config, day, text, uid); setThread((t) => [...t, c]); }} />
          ) : <p className="muted">Loading…</p>}
        </>
      )}
      <p className="danger"><button className="link" onClick={remove}>Stop coaching {personName(client)}</button></p>
    </>
  );
}
