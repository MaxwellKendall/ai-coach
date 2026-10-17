import { useEffect, useState } from "react";
import { finishSignIn, idToken, signIn, signOut, startLink, user, type Config, type Provider, type User } from "./auth";
import { BillingPage } from "./BillingPage";
import { ClientPage, ClientsPage } from "./ClientsPage";
import { HistoryView } from "./HistoryView";
import { here, href } from "./paths";
import { ProgramPage } from "./ProgramPage";
import { comments, postComment, pullAll, type Comment, type Unit } from "./sync";

const APP = "Barbrabell";

function Logo() {
  return (
    <svg className="logo" viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3" y="13" width="5" height="8" rx="1.5" />
      <rect x="9.5" y="8.5" width="5" height="12.5" rx="1.5" />
      <rect x="16" y="3" width="5" height="18" rx="1.5" />
    </svg>
  );
}

type State = { phase: "loading" } | { phase: "out"; error?: string } | { phase: "in"; me: User; notice?: string };

export default function App() {
  const [config, setConfig] = useState<Config>();
  const [state, setState] = useState<State>({ phase: "loading" });

  useEffect(() => {
    (async () => {
      const loaded: Config = await (await fetch(`${import.meta.env.BASE_URL}config.json`)).json();
      setConfig(loaded);
      let notice: string | undefined;
      try {
        notice = await finishSignIn(loaded);
      } catch (error) {
        // A link that failed leaves the account signed in; say why.
        const token = await idToken(loaded);
        return setState(token ? { phase: "in", me: user(token), notice: (error as Error).message } : { phase: "out", error: (error as Error).message });
      }
      const token = await idToken(loaded);
      setState(token ? { phase: "in", me: user(token), notice } : { phase: "out" });
    })().catch(() => setState({ phase: "out", error: "Couldn't reach the server. Check your connection and reload." }));
  }, []);

  if (!config || state.phase === "loading") return null;
  if (state.phase === "out") return <SignIn config={config} error={state.error} />;
  return <Dashboard config={config} me={state.me} notice={state.notice} />;
}

function SignIn({ config, error }: { config: Config; error?: string }) {
  const providers = (["google", "apple"] as Provider[]).filter((p) => config.providers.includes(p));
  return (
    <main className="signin">
      <div className="brand"><Logo />{APP}</div>
      <h1>Your training, on a bigger screen</h1>
      <p className="lede">Edit your program and look back at every session. Coach others? Invite your clients, write their programs and see how their training goes.</p>
      <p className="lede">Sign in with the account you use in the app.</p>
      <div className="buttons">
        {providers.map((p) => (
          <button key={p} className="button primary" onClick={() => signIn(config, p)}>
            Continue with {p === "google" ? "Google" : "Apple"}
          </button>
        ))}
      </div>
      {error && <p className="error" role="alert">{error}</p>}
    </main>
  );
}

/** The address bar's path, kept in step with the nav without reloading the page. */
export function usePath(): [string, (path: string) => (e?: React.MouseEvent) => void] {
  const [path, setPath] = useState(here);
  useEffect(() => {
    const onPop = () => setPath(here());
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const go = (to: string) => (e?: React.MouseEvent) => {
    e?.preventDefault();
    history.pushState(null, "", href(to));
    setPath(to);
    window.scrollTo(0, 0);
  };
  return [path, go];
}

function Dashboard({ config, me, notice }: { config: Config; me: User; notice?: string }) {
  const [path, go] = usePath();
  // FIT-137: back from linking, the Account page says how it went.
  useEffect(() => { if (notice) go("/account")(); }, [notice]);
  const link = (to: string, label: string, active: boolean) => (
    <a href={href(to)} className={active ? "current" : undefined} aria-current={active ? "page" : undefined} onClick={go(to)}>{label}</a>
  );
  return (
    <div className="shell">
      <aside className="nav">
        <div className="brand"><Logo />{APP}</div>
        <nav>
          {link("/", "Program", path === "/")}
          {link("/history", "History", path.startsWith("/history"))}
          {link("/clients", "Clients", path.startsWith("/clients"))}
          {link("/billing", "Billing", path.startsWith("/billing"))}
          {link("/account", "Account", path.startsWith("/account"))}
        </nav>
        <div className="account">
          <div className="who">
            <strong>{me.name ?? me.email ?? "Signed in"}</strong>
            {me.name && me.email && <span>{me.email}</span>}
          </div>
          <button className="link" onClick={() => signOut(config)}>Sign out</button>
        </div>
      </aside>
      <main className="content">
        {path.startsWith("/billing") ? (
          <BillingPage config={config} />
        ) : path.startsWith("/account") ? (
          <AccountPage config={config} me={me} notice={notice} />
        ) : path.startsWith("/history") ? (
          <HistoryPage config={config} me={me} />
        ) : path.startsWith("/clients/") ? (
          <ClientPage key={path} config={config} me={me} uid={path.slice("/clients/".length)} go={go} />
        ) : path.startsWith("/clients") ? (
          <ClientsPage config={config} me={me} go={go} />
        ) : (
          <ProgramPage config={config} me={me} empty={<Empty config={config} me={me} go={go} />} />
        )}
      </main>
    </div>
  );
}

function HistoryPage({ config, me }: { config: Config; me: User }) {
  const [units, setUnits] = useState<Map<string, Unit>>();
  const [thread, setThread] = useState<Comment[]>([]);
  const [error, setError] = useState<string>();
  useEffect(() => {
    pullAll(config).then(setUnits, (e: Error) => setError(e.message));
    // FIT-132: a coach's replies, and mine.
    comments(config).then(setThread, () => setThread([]));
  }, [config]);
  return (
    <>
      <header className="page"><h1>History</h1></header>
      {error ? <p className="error" role="alert">Couldn't load your history: {error}</p>
        : units ? (
          <HistoryView units={units} comments={thread} me={me.uid}
                       onReply={thread.length ? async (day, text) => { const c = await postComment(config, day, text); setThread((t) => [...t, c]); } : undefined} />
        ) : <p className="muted">Loading…</p>}
    </>
  );
}

function Empty({ config, me, go }: { config: Config; me: User; go: (path: string) => (e?: React.MouseEvent) => void }) {
  return (
    <>
      <header className="page">
        <h1>This week</h1>
      </header>
      {/* FIT-130: a coach may not train with the app themselves; their work is on Clients. */}
      <div className="empty coach">
        <h2>Coaching clients?</h2>
        <p className="muted">Invite them, write their programs and follow their training.</p>
        <a className="button primary" href={href("/clients")} onClick={go("/clients")}>Go to Clients</a>
      </div>
      <div className="empty">
        <h2>Training yourself?</h2>
        <p className="muted">
          Open {APP} on your iPhone, signed in as {me.email ?? me.name ?? "this account"}, and your program shows up here.
        </p>
        {me.provider && (
          <p className="muted">
            You're signed in with {me.provider === "google" ? "Google" : "Apple"}. If the app uses{" "}
            {me.provider === "google" ? "Apple" : "Google"},{" "}
            <button className="link" onClick={() => startLink(config, me.provider === "google" ? "apple" : "google")}>
              link your {me.provider === "google" ? "Apple" : "Google"} sign-in</button> and they'll be one account.
          </p>
        )}
      </div>
    </>
  );
}

/** FIT-137: the sign-ins on this account, and linking the other one. */
function AccountPage({ config, me, notice }: { config: Config; me: User; notice?: string }) {
  const all: Provider[] = (["apple", "google"] as Provider[]).filter((p) => config.providers.includes(p));
  const label = (p: Provider) => (p === "google" ? "Google" : "Apple");
  return (
    <>
      <header className="page">
        <h1>Account</h1>
        {notice && <p className="status" role="status">{notice}</p>}
      </header>
      <div className="empty account-page">
        <p><strong>{me.name ?? me.email ?? "Your account"}</strong>{me.name && me.email ? <span className="muted"> · {me.email}</span> : null}</p>
        <ul className="signins">
          {all.map((p) => (
            <li key={p}>
              <span>{label(p)}</span>
              {me.linked.includes(p) ? (
                <span className="muted">Signs in to this account</span>
              ) : (
                <button className="button" onClick={() => startLink(config, p)}>Link {label(p)}</button>
              )}
            </li>
          ))}
        </ul>
        <p className="muted">Linked sign-ins open the same account, in the app and here. Linking asks you to sign in once with that provider.</p>
      </div>
    </>
  );
}
