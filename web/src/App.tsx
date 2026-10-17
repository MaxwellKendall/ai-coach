import { useEffect, useState } from "react";
import { finishSignIn, idToken, signIn, signOut, user, type Config, type Provider, type User } from "./auth";
import { HistoryView } from "./HistoryView";
import { ProgramPage } from "./ProgramPage";
import { pullAll, type Unit } from "./sync";

const APP = "Rep & Recipe";

function Logo() {
  return (
    <svg className="logo" viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3" y="13" width="5" height="8" rx="1.5" />
      <rect x="9.5" y="8.5" width="5" height="12.5" rx="1.5" />
      <rect x="16" y="3" width="5" height="18" rx="1.5" />
    </svg>
  );
}

type State = { phase: "loading" } | { phase: "out"; error?: string } | { phase: "in"; me: User };

export default function App() {
  const [config, setConfig] = useState<Config>();
  const [state, setState] = useState<State>({ phase: "loading" });

  useEffect(() => {
    (async () => {
      const loaded: Config = await (await fetch("/config.json")).json();
      setConfig(loaded);
      try {
        await finishSignIn(loaded);
      } catch (error) {
        return setState({ phase: "out", error: (error as Error).message });
      }
      const token = await idToken(loaded);
      setState(token ? { phase: "in", me: user(token) } : { phase: "out" });
    })().catch(() => setState({ phase: "out", error: "Couldn't reach the server. Check your connection and reload." }));
  }, []);

  if (!config || state.phase === "loading") return null;
  if (state.phase === "out") return <SignIn config={config} error={state.error} />;
  return <Dashboard config={config} me={state.me} />;
}

function SignIn({ config, error }: { config: Config; error?: string }) {
  const providers = (["google", "apple"] as Provider[]).filter((p) => config.providers.includes(p));
  return (
    <main className="signin">
      <div className="brand"><Logo />{APP}</div>
      <h1>Your program, on a bigger screen</h1>
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
  const [path, setPath] = useState(location.pathname);
  useEffect(() => {
    const onPop = () => setPath(location.pathname);
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);
  const go = (to: string) => (e?: React.MouseEvent) => {
    e?.preventDefault();
    history.pushState(null, "", to);
    setPath(to);
    window.scrollTo(0, 0);
  };
  return [path, go];
}

function Dashboard({ config, me }: { config: Config; me: User }) {
  const [path, go] = usePath();
  const link = (to: string, label: string, active: boolean) => (
    <a href={to} className={active ? "current" : undefined} aria-current={active ? "page" : undefined} onClick={go(to)}>{label}</a>
  );
  return (
    <div className="shell">
      <aside className="nav">
        <div className="brand"><Logo />{APP}</div>
        <nav>
          {link("/", "Program", path === "/")}
          {link("/history", "History", path.startsWith("/history"))}
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
        {path.startsWith("/history") ? (
          <HistoryPage config={config} />
        ) : (
          <ProgramPage config={config} me={me} empty={<Empty config={config} me={me} />} />
        )}
      </main>
    </div>
  );
}

function HistoryPage({ config }: { config: Config }) {
  const [units, setUnits] = useState<Map<string, Unit>>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    pullAll(config).then(setUnits, (e: Error) => setError(e.message));
  }, [config]);
  return (
    <>
      <header className="page"><h1>History</h1></header>
      {error ? <p className="error" role="alert">Couldn't load your history: {error}</p>
        : units ? <HistoryView units={units} /> : <p className="muted">Loading…</p>}
    </>
  );
}

function Empty({ config, me }: { config: Config; me: User }) {
  return (
    <>
      <header className="page">
        <h1>This week</h1>
      </header>
      <div className="empty">
        <h2>Nothing here yet</h2>
        <p className="muted">
          Open {APP} on your iPhone, signed in as {me.email ?? me.name ?? "this account"}, and your program shows up here.
        </p>
        {me.provider && (
          <p className="muted">
            You're signed in with {me.provider === "google" ? "Google" : "Apple"}. If the app uses{" "}
            {me.provider === "google" ? "Apple" : "Google"}, that's a separate account:{" "}
            <button className="link" onClick={() => signOut(config)}>sign out</button> and continue with{" "}
            {me.provider === "google" ? "Apple" : "Google"}.
          </p>
        )}
      </div>
    </>
  );
}
