import { idToken, type Config } from "./auth";
import { estimated1RMs, loggedSets } from "./progress";
import type { Measurement, PlanRow, Unit } from "./sync";

// FIT-141: "Design it for me" in Send a program. Claude Haiku lays out one week for the client from their profile,
// goals and recent lifts, through the same proxy the app uses (aiMessages, FIT-102), answering with one tool so the
// week comes back as data. The model chooses the training (FIT-67); the web's plan checks (guard.ts) warn after, and
// the coach edits before sending.

export type CatalogEntry = { slug: string; name: string; equipment: string[]; pattern: string | null; tags: string[] };
type Profile = {
  age?: number; trainingDays?: number[]; sessionMinutes?: number; equipment?: string[]; style?: string;
  injuredAreas?: string[]; avoidExercises?: string[]; maxWeeklySets?: number;
};
type Goal = { metric: string; target: number; unit: string; deadline?: number; status: string };

export const MODEL = "claude-haiku-5-5";
const PATTERNS = ["squat", "hinge", "push", "pull", "lunge", "shoulders", "core", "arms", "legs", "calves"];
const PER_PATTERN = 12;

/** What Claude chooses from: exercises the client's equipment allows, the first few of each main pattern. */
export function choices(catalog: CatalogEntry[], profile?: Profile): CatalogEntry[] {
  const kit = profile?.equipment ? new Set(profile.equipment) : undefined;
  const avoid = new Set(profile?.avoidExercises ?? []);
  const usable = catalog.filter((t) => (!kit || t.equipment.every((e) => kit.has(e))) && !avoid.has(t.slug));
  return PATTERNS.flatMap((p) => usable.filter((t) => t.pattern === p).slice(0, PER_PATTERN));
}

/** The client as the prompt describes them. Days are Sunday = 0, as the template's are. */
export function brief(units: Map<string, Unit>, names: Map<string, string>) {
  const profileBody = units.get("profile")?.body;
  const profile: Profile | undefined = profileBody ? JSON.parse(profileBody) : undefined;
  const goals = [...units.entries()].filter(([k, u]) => k.startsWith("goal#") && u.body)
    .map(([, u]) => JSON.parse(u.body!) as Goal).filter((g) => g.status === "active");
  const maxes = Object.entries(estimated1RMs(loggedSets(units))).sort((a, b) => b[1] - a[1]).slice(0, 8);
  const days = profile?.trainingDays?.map((d) => (d + 1) % 7).sort();
  const goalText = (g: Goal) => {
    const [slug, metric] = g.metric.split(".");
    const what = metric === "1rm_lb" ? `${names.get(slug) ?? slug} ${g.target} lb (one-rep max)` : metric === "reps" ? `${g.target} ${names.get(slug) ?? slug}` : `${g.metric} ${g.target} ${g.unit}`;
    return g.deadline ? `${what} by ${new Date(g.deadline * 1000).toISOString().slice(0, 10)}` : what;
  };
  return {
    profile,
    text: [
      profile?.age ? `Age ${profile.age}.` : "",
      days?.length ? `Trains on weekdays ${days.join(", ")} (0 = Sunday), ${profile?.sessionMinutes ?? 45} minutes a session.` : "",
      profile?.style ? `Style: ${profile.style}.` : "",
      profile?.injuredAreas?.length ? `Injured or sore: ${profile.injuredAreas.join(", ")}.` : "",
      profile?.maxWeeklySets ? `At most ${profile.maxWeeklySets} working sets a week.` : "",
      goals.length ? `Goals: ${goals.map(goalText).join("; ")}.` : "No goals set.",
      maxes.length ? `Estimated maxes now: ${maxes.map(([s, v]) => `${names.get(s) ?? s} ${Math.round(v)} lb`).join(", ")}.` : "No logged lifts yet.",
    ].filter(Boolean).join(" "),
  };
}

const answerTool = (slugs: string[]) => ({
  name: "answer",
  description: "The week's sessions.",
  input_schema: {
    type: "object",
    required: ["days"],
    properties: {
      days: {
        type: "array",
        items: {
          type: "object",
          required: ["weekday", "slot", "exercises"],
          properties: {
            weekday: { type: "integer", minimum: 0, maximum: 6, description: "0 = Sunday" },
            slot: { type: "string", description: "The session's short name, like Lower A" },
            exercises: {
              type: "array",
              items: {
                type: "object",
                required: ["slug", "sets", "main"],
                properties: {
                  slug: { type: "string", enum: slugs },
                  sets: { type: "integer", minimum: 1, maximum: 6 },
                  reps: { type: "integer", minimum: 1, maximum: 30 },
                  seconds: { type: "integer", minimum: 10, maximum: 600 },
                  load_lb: { type: "number", minimum: 0 },
                  main: { type: "boolean", description: "The session's main lift" },
                },
              },
            },
          },
        },
      },
    },
  },
});

export function request(clientText: string, menu: CatalogEntry[], note: string) {
  const list = menu.map((t) => `${t.slug} (${t.name}; ${t.pattern}${t.equipment.length ? `; ${t.equipment.join(", ")}` : "; bodyweight"})`).join("\n");
  return {
    model: MODEL,
    max_tokens: 4000,
    system: "You are a strength coach writing one training week for a client. Choose exercises only from the list. "
      + "Put sessions on the days the client trains. Each session: one main lift first, then 3 to 5 accessories. "
      + "Cover a squat or lunge, a hinge, a push and a pull across the week. Loads in lb: barbell lifts in 5 lb steps, "
      + "working sets around 75 to 85% of the estimated max for main lifts; leave load out for bodyweight and timed holds. "
      + "Answer only by calling the answer tool.",
    messages: [{
      role: "user",
      content: `Client: ${clientText}\n${note ? `What the coach wants: ${note}\n` : ""}\nExercises (slug, name; pattern; equipment):\n${list}`,
    }],
    tools: [answerTool(menu.map((t) => t.slug))],
    tool_choice: { type: "tool", name: "answer" },
  };
}

type Answer = { days: { weekday: number; slot: string; exercises: { slug: string; sets: number; reps?: number; seconds?: number; load_lb?: number; main: boolean }[] }[] };

/** The answer as the builder's week (rows by weekday), dropping anything not on the menu. */
export function toWeek(answer: Answer, menu: CatalogEntry[], firstSunday: Date): PlanRow[][] {
  const allowed = new Set(menu.map((t) => t.slug));
  const week: PlanRow[][] = Array.from({ length: 7 }, () => []);
  for (const day of answer.days ?? []) {
    if (!Number.isInteger(day.weekday) || day.weekday < 0 || day.weekday > 6 || week[day.weekday].length) continue;
    const date = new Date(firstSunday.getFullYear(), firstSunday.getMonth(), firstSunday.getDate() + day.weekday, 7);
    week[day.weekday] = (day.exercises ?? []).filter((e) => allowed.has(e.slug)).map((e, i) => {
      const targets: Measurement[] = [{ metric: "sets", value: Math.max(1, Math.min(6, Math.round(e.sets))), unit: "sets" }];
      if (e.seconds && !e.reps) targets.push({ metric: "duration_s", value: e.seconds, unit: "s" });
      else if (e.reps) targets.push({ metric: "reps", value: e.reps, unit: "reps" });
      if (e.load_lb && e.load_lb > 0) targets.push({ metric: "load_lb", value: e.load_lb, unit: "lb" });
      return { id: crypto.randomUUID(), kind: "workout", at: date.getTime() / 1000 + i, slot: day.slot, template: e.slug,
               targets, note: "", main: !!e.main, pinned: false };
    });
  }
  return week;
}

/** One request to Claude through the proxy; the tool's input, or why not. */
export async function design(config: Config, body: unknown): Promise<Answer> {
  const token = await idToken(config);
  if (!token) throw new Error("Signed out");
  const response = await fetch(config.graphqlUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: token },
    body: JSON.stringify({ query: "mutation($r: AWSJSON!) { aiMessages(request: $r) }", variables: { r: JSON.stringify(body) } }),
  });
  const json = await response.json();
  if (json.errors?.length) throw new Error(json.errors[0].message);
  const reply = JSON.parse(json.data.aiMessages);
  if (reply.status !== 200) throw new Error(reply.body?.error?.message ?? `Claude answered ${reply.status}`);
  const use = (reply.body.content ?? []).find((c: { type: string }) => c.type === "tool_use");
  if (!use) throw new Error("Claude didn't answer with a week. Try again.");
  return use.input as Answer;
}
