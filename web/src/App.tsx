import { useEffect, useMemo, useState } from "react";
import { finishSignIn, idToken, signIn, signOut, user, type Config, type Provider, type User } from "./auth";
import catalog from "./catalog.json";
import { describe, week } from "./program";
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

function Dashboard({ config, me }: { config: Config; me: User }) {
  return (
    <div className="shell">
      <aside className="nav">
        <div className="brand"><Logo />{APP}</div>
        <nav>
          <a className="current" href="/" aria-current="page">Program</a>
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
        <Program config={config} me={me} />
      </main>
    </div>
  );
}

const names = new Map(catalog.map((t) => [t.slug, t.name]));
const weekday = new Intl.DateTimeFormat(undefined, { weekday: "short" });
const monthDay = new Intl.DateTimeFormat(undefined, { month: "long", day: "numeric" });

function Program({ config, me }: { config: Config; me: User }) {
  const [units, setUnits] = useState<Map<string, Unit>>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    pullAll(config).then(setUnits, (e: Error) => setError(e.message));
  }, [config]);

  const today = new Date();
  const days = useMemo(() => (units ? week(units, today, names) : []), [units]);

  if (error) return <p className="error" role="alert">Couldn't load your program: {error}</p>;
  if (!units) return <p className="muted">Loading your program…</p>;

  const hasPlan = [...units.keys()].some((k) => k.startsWith("plan#") && !units.get(k)!.deleted);
  return (
    <>
      <header className="page">
        <p className="eyebrow">Week of {monthDay.format(days[0].date)}</p>
        <h1>This week</h1>
      </header>
      {!hasPlan ? (
        <div className="empty">
          <h2>Nothing here yet</h2>
          <p className="muted">
            Open {APP} on your iPhone, signed in as {me.email ?? me.name ?? "this account"}, and your program shows up here.
          </p>
        </div>
      ) : (
        <ol className="days">
          {days.map((day) => {
            const isToday = day.key === days.find((d) => d.date.toDateString() === today.toDateString())?.key;
            return (
              <li key={day.key} className={`day${isToday ? " today" : ""}${day.lines.length ? "" : " rest"}`}>
                <div className="date">
                  <span>{weekday.format(day.date)}</span>
                  <strong>{day.date.getDate()}</strong>
                </div>
                <div className="session">
                  {day.lines.length ? (
                    <>
                      <h3>
                        {day.title ?? "Workout"}
                        {day.done && <span className="done">Done</span>}
                      </h3>
                      <ul>
                        {day.lines.map((line, i) => (
                          <li key={i}>
                            <span>{line.exercise}</span>
                            <span className="muted">{describe(line)}</span>
                          </li>
                        ))}
                      </ul>
                    </>
                  ) : (
                    <p className="muted">{day.done ? "Trained" : "Rest"}</p>
                  )}
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </>
  );
}
