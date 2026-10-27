import { useEffect, useState } from "react";
import { KIT } from "../../shared/readyPrograms";
import { idToken, signIn, type Config, type Provider } from "./auth";
import catalog from "./catalog.json";
import { dose, exerciseName, headline, plan, PRICE, PRODUCT, savePending, startTrial, takePending, TRIAL_DAYS, type Answers, type Plan } from "./start";

type Step = "have" | "days" | "plan";

/** FIT-281: the quiz an ad opens, then the plan and its free trial. Signed out, the trial asks to sign in first and
 * picks up where it left off; /start/thanks is where Checkout comes back to. */
export function StartPage({ config, path }: { config: Config; path: string }) {
  useEffect(() => { document.title = PRODUCT; }, []);
  return (
    <main className="start">
      <div className="brand">{PRODUCT}</div>
      {path.startsWith("/start/thanks") ? <Thanks /> : <Quiz config={config} />}
    </main>
  );
}

function Quiz({ config }: { config: Config }) {
  const [step, setStep] = useState<Step>("have");
  const [have, setHave] = useState<Set<string>>(new Set());
  const [days, setDays] = useState(3);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string>();
  const [signingIn, setSigningIn] = useState(false);

  // Back from sign-in: straight on to Checkout with the answers from before.
  useEffect(() => {
    const pending = takePending();
    if (pending) checkout(pending);
  }, []);

  async function checkout(answers: Answers) {
    setWorking(true);
    setError(undefined);
    try {
      if (!(await idToken(config))) {
        savePending(answers);
        setSigningIn(true);
        return;
      }
      const url = await startTrial(config, answers);
      if (url) location.assign(url);
      else setError("The free trial isn't open yet. Try again soon.");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  }

  const all = new Set(KIT.flatMap((k) => k.equipment));
  const gym = [...all].every((e) => have.has(e));
  const toggle = (equipment: string[], on: boolean) =>
    setHave((h) => new Set(on ? [...h, ...equipment] : [...h].filter((e) => !equipment.includes(e))));

  if (step === "have") {
    return (
      <section>
        <p className="eyebrow">1 of 2</p>
        <h1>What do you have?</h1>
        <p className="lede">Tick what you can use. Your plan only uses these.</p>
        <div className="choices">
          <Tick label="A full gym" on={gym} onChange={(on) => toggle([...all], on)} />
          {KIT.map((k) => <Tick key={k.name} label={k.name} on={k.equipment.every((e) => have.has(e))} onChange={(on) => toggle(k.equipment, on)} />)}
        </div>
        <p className="muted small">{have.size ? " " : "Nothing ticked: a body-weight plan."}</p>
        <button className="button primary" onClick={() => setStep("days")}>Continue</button>
      </section>
    );
  }

  if (step === "days") {
    return (
      <section>
        <p className="eyebrow">2 of 2</p>
        <h1>How many days a week?</h1>
        <p className="lede">Pick what you can keep up. You'll choose the days in the app.</p>
        <div className="choices">
          {[2, 3, 4, 5, 6].map((n) => (
            <button key={n} className="choice" onClick={() => { setDays(n); setStep("plan"); }}>
              {n} days<span aria-hidden="true">›</span>
            </button>
          ))}
        </div>
        <button className="link" onClick={() => setStep("have")}>Back</button>
      </section>
    );
  }

  const made = plan(have, days);
  if (!made) return null;
  return (
    <section>
      <p className="eyebrow">Your {made.program.weeks}-week plan</p>
      <h1>{headline(made)}</h1>
      <p className="lede">If every session goes to plan: a little heavier each time, by the program's rule, with a lighter week in the middle.</p>
      {made.reveal && <Chart plan={made} />}
      <div className="program">
        <h2>{made.program.name}</h2>
        <p className="muted">{made.program.summary}</p>
        <p className="small">{made.answers.days.length} days a week · about {made.program.minutes} min a session · {made.program.weeks} weeks</p>
        <Week plan={made} />
      </div>
      <div className="trial">
        {signingIn ? (
          <>
            <p><strong>Sign in to start your free trial.</strong> Use the same account you'll sign in to the app with.</p>
            <div className="buttons">
              {(["apple", "google"] as Provider[]).filter((p) => config.providers.includes(p)).map((p) => (
                <button key={p} className="button primary" onClick={() => signIn(config, p)}>
                  Continue with {p === "google" ? "Google" : "Apple"}
                </button>
              ))}
            </div>
          </>
        ) : (
          <button className="button primary" disabled={working} onClick={() => checkout(made.answers)}>
            {working ? "Starting…" : `Start my ${TRIAL_DAYS}-day free trial`}
          </button>
        )}
        <p className="muted small">Free for {TRIAL_DAYS} days, then {PRICE}. Cancel any time before the trial ends and you won't be charged.</p>
        {error && <p className="error" role="alert">{error}</p>}
      </div>
      <button className="link" onClick={() => setStep("days")}>Change my answers</button>
    </section>
  );
}

function Tick({ label, on, onChange }: { label: string; on: boolean; onChange: (on: boolean) => void }) {
  return (
    <button className="choice" aria-pressed={on} onClick={() => onChange(!on)}>
      {label}<span className={on ? "tick on" : "tick"} aria-hidden="true">{on ? "✓" : ""}</span>
    </button>
  );
}

/** The promised lift, week by week: a line rising to the last week, the deload's flat step in it. */
function Chart({ plan }: { plan: Plan }) {
  const loads = plan.reveal!.loads;
  const [w, h, pad] = [320, 140, 8];
  const low = loads[0];
  const high = Math.max(...loads);
  const x = (i: number) => pad + (i / (loads.length - 1)) * (w - pad * 2);
  const y = (v: number) => h - pad - (high === low ? 0 : ((v - low) / (high - low)) * (h - pad * 2));
  const points = loads.map((v, i) => `${x(i)},${y(v)}`).join(" ");
  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${w} ${h}`} role="img" aria-label={headline(plan)}>
        <polyline points={points} fill="none" stroke="currentColor" strokeWidth="3" strokeLinejoin="round" strokeLinecap="round" />
        <circle cx={x(loads.length - 1)} cy={y(loads.at(-1)!)} r="5" className="end" />
      </svg>
      <figcaption className="muted small"><span>Today</span><span>Week {loads.length - 1}</span></figcaption>
    </figure>
  );
}

/** Each session once, with its exercises and doses. */
function Week({ plan }: { plan: Plan }) {
  const seen = new Set<string>();
  const sessions = plan.program.sessions.filter((s) => !seen.has(s.name) && seen.add(s.name));
  const have = new Set(plan.answers.have);
  const pick = (choices: string[]) => choices.find((c) => catalogAllows(c, have)) ?? choices[0];
  return (
    <div className="week">
      {sessions.map((s) => (
        <div key={s.name}>
          <p className="eyebrow">{s.name}</p>
          <ul>
            {s.exercises.map((item, i) => {
              const choices = item.ladder ?? [item.exercise, ...(item.or ?? [])].filter((c): c is string => Boolean(c));
              return <li key={i}><span>{exerciseName(pick(choices))}</span><span className="muted">{dose(item)}</span></li>;
            })}
          </ul>
        </div>
      ))}
    </div>
  );
}

const equipmentOf = new Map((catalog as { slug: string; equipment: string[] }[]).map((e) => [e.slug, e.equipment]));
/** The exercise needs only what they have, as the app's week picks among a program's choices. */
const catalogAllows = (slug: string, have: Set<string>) => (equipmentOf.get(slug) ?? []).every((e) => have.has(e));

function Thanks() {
  return (
    <section>
      <p className="eyebrow">Your trial has started</p>
      <h1>Your plan is waiting in the app.</h1>
      <p className="lede">Open {PRODUCT} on your iPhone and sign in with the account you just used. Your program is on Today, ready for its first session.</p>
      <p className="muted small">Nothing is charged until the {TRIAL_DAYS}-day trial ends. The receipt from Stripe says how to cancel.</p>
    </section>
  );
}
