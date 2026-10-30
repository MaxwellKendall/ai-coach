import { useEffect, useState } from "react";
import { KIT, type Goal } from "../../shared/readyPrograms";
import type { Config } from "./auth";
import catalog from "./catalog.json";
import {
  dose, exerciseName, headline, liftOf, pick, plan, PRODUCT, type Plan,
} from "./start";

type Step = "goal" | "lifted" | "have" | "days" | "recent" | "plan";

/** "What's your goal?", in the app's words (Features/Goals/ProgramPicker.swift). */
const GOALS: { goal: Goal; title: string; detail: string; plan: string }[] = [
  { goal: "strength", title: "Get stronger", detail: "Lift heavier on the big lifts.", plan: "to get stronger" },
  { goal: "muscle", title: "Build muscle", detail: "Add size and shape.", plan: "to build muscle" },
  { goal: "start", title: "Start lifting", detail: "New to it: learn the lifts, then build.", plan: "to start lifting" },
];

/** FIT-281: the quiz, then the plan revealed. FIT-295: free; it ends in the app, where Train on your own asks the same. */
export function StartPage({ config }: { config: Config; path: string }) {
  useEffect(() => { document.title = PRODUCT; }, []);
  return (
    <main className="start">
      <div className="brand">{PRODUCT}</div>
      <Quiz config={config} />
    </main>
  );
}

function Quiz({ config }: { config: Config }) {
  const [step, setStep] = useState<Step>("goal");
  const [goal, setGoal] = useState<Goal>();
  const [lifted, setLifted] = useState<boolean>();
  const [have, setHave] = useState<Set<string>>(new Set());
  const [days, setDays] = useState(3);
  const [weight, setWeight] = useState("");
  const [reps, setReps] = useState("");
  const [recent, setRecent] = useState<{ weight: number; reps: number }>();

  // The steps this person sees: someone starting out isn't asked if they've lifted, and only someone who has, with a
  // lift to load, is asked a recent set. Until the answers say, the count assumes the longest.
  const lift = liftOf(pick({ goal, lifted, have, days }));
  const early = step === "goal" || step === "lifted" || step === "have" || step === "days";
  const steps: Step[] = [
    "goal", ...(goal === "start" ? [] : ["lifted" as const]), "have", "days",
    ...(lifted !== false && (early || lift) ? ["recent" as const] : []),
  ];
  const count = (s: Step) => <p className="eyebrow">{steps.indexOf(s) + 1} of {steps.length}</p>;
  const back = (s: Step) => <button className="link" onClick={() => setStep(steps[steps.indexOf(s) - 1])}>Back</button>;

  if (step === "goal") {
    return (
      <section>
        {count("goal")}
        <h1>What's your goal?</h1>
        <p className="lede">Your plan is built around it.</p>
        <div className="choices">
          {GOALS.map((g) => (
            <button key={g.goal} className="choice" onClick={() => {
              setGoal(g.goal);
              if (g.goal === "start") setLifted(false);
              setStep(g.goal === "start" ? "have" : "lifted");
            }}>
              <span className="stack"><strong>{g.title}</strong><span className="muted small">{g.detail}</span></span><span aria-hidden="true">›</span>
            </button>
          ))}
        </div>
      </section>
    );
  }

  if (step === "lifted") {
    return (
      <section>
        {count("lifted")}
        <h1>Have you lifted weights before?</h1>
        <p className="lede">Your plan starts where you are.</p>
        <div className="choices">
          {([[true, "Yes"], [false, "Not really"]] as const).map(([yes, label]) => (
            <button key={label} className="choice" onClick={() => { setLifted(yes); setStep("have"); }}>
              {label}<span aria-hidden="true">›</span>
            </button>
          ))}
        </div>
        {back("lifted")}
      </section>
    );
  }

  const all = new Set(KIT.flatMap((k) => k.equipment));
  const gym = [...all].every((e) => have.has(e));
  const toggle = (equipment: string[], on: boolean) =>
    setHave((h) => new Set(on ? [...h, ...equipment] : [...h].filter((e) => !equipment.includes(e))));

  if (step === "have") {
    return (
      <section>
        {count("have")}
        <h1>What do you have?</h1>
        <p className="lede">Tick what you can use. Your plan only uses these.</p>
        <div className="choices">
          <Tick label="A full gym" on={gym} onChange={(on) => toggle([...all], on)} />
          {KIT.map((k) => <Tick key={k.name} label={k.name} on={k.equipment.every((e) => have.has(e))} onChange={(on) => toggle(k.equipment, on)} />)}
        </div>
        <p className="muted small">{have.size ? " " : "Nothing ticked: a body-weight plan."}</p>
        <button className="button primary" onClick={() => setStep("days")}>Continue</button>
        {back("have")}
      </section>
    );
  }

  if (step === "days") {
    return (
      <section>
        {count("days")}
        <h1>How many days a week?</h1>
        <p className="lede">Pick what you can keep up. You'll choose the days in the app.</p>
        <div className="choices">
          {[2, 3, 4, 5, 6].map((n) => (
            <button key={n} className="choice" onClick={() => {
              setDays(n);
              setStep(lifted && liftOf(pick({ goal, lifted, have, days: n })) ? "recent" : "plan");
            }}>
              {n} days<span aria-hidden="true">›</span>
            </button>
          ))}
        </div>
        {back("days")}
      </section>
    );
  }

  if (step === "recent" && lift) {
    const perHand = pick({ goal, lifted, have, days })?.place === "dumbbells";
    const set = { weight: Number(weight), reps: Number(reps) };
    const valid = set.weight > 0 && set.weight <= 1000 && Number.isInteger(set.reps) && set.reps >= 1 && set.reps <= 12;
    return (
      <section>
        {count("recent")}
        <h1>Your best recent {exerciseName(lift)}</h1>
        <p className="lede">A hard set from the last few months, 1 to 12 reps. Your plan starts a little under it.</p>
        <div className="recent">
          <label><input inputMode="decimal" autoFocus placeholder="0" aria-label={perHand ? "Weight, lb a hand" : "Weight, lb"} value={weight} onChange={(e) => setWeight(e.target.value)} />
            <span className="muted">{perHand ? "lb a hand" : "lb"}</span></label>
          <span className="muted" aria-hidden="true">×</span>
          <label><input inputMode="numeric" placeholder="0" aria-label="Reps" value={reps} onChange={(e) => setReps(e.target.value)} />
            <span className="muted">reps</span></label>
        </div>
        <button className="button primary" disabled={!valid} onClick={() => { setRecent(set); setStep("plan"); }}>Continue</button>
        <button className="link" onClick={() => { setRecent(undefined); setStep("plan"); }}>I'm not sure</button>
        {back("recent")}
      </section>
    );
  }

  const made = plan({ goal, lifted, have, days, recent });
  if (!made) return null;
  return (
    <section>
      <p className="eyebrow">Your {made.program.weeks}-week plan {GOALS.find((g) => g.goal === goal)?.plan}</p>
      <h1>{headline(made)}</h1>
      <p className="lede">
        {made.answers.recent
          ? `From your ${made.answers.recent.weight} × ${made.answers.recent.reps}: a little under it to start, back to it fast, then heavier a step a week, with a lighter week in the middle.`
          : "If every session goes to plan: a little heavier each time, by the program's rule, with a lighter week in the middle."}
      </p>
      {made.reveal && <Chart plan={made} />}
      <div className="program">
        <h2>{made.program.name}</h2>
        <p className="muted">{made.program.summary}</p>
        <p className="small">{made.answers.days.length} days a week · about {made.program.minutes} min a session · {made.program.weeks} weeks</p>
        <Week plan={made} />
      </div>
      <div className="trial">
        {config.appStoreUrl
          ? <a className="button primary" href={config.appStoreUrl}>Get {PRODUCT} free</a>
          : <p><strong>{PRODUCT} is free on iPhone,</strong> coming to the App Store soon.</p>}
        <p className="muted small">In the app, choose “No coach? Train on your own” and answer the same way: this plan starts on Today, free.</p>
      </div>
      <button className="link" onClick={() => setStep("goal")}>Change my answers</button>
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
