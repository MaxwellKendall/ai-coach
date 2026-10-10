/**
 * FIT-105: the share pages on this Mac, from sample data. `npm run web`, then open http://localhost:8787.
 * The renderers are the ones the Lambda will serve (lambda/sharePages.ts); only the store differs.
 */
import { createServer } from "node:http";
import { route, type Invite, type Program, type Recap, type Site, type Store, type Win } from "../lambda/sharePages.ts";

const port = Number(process.env.PORT ?? 8787);

const site: Site = {
  appName: "Rep & Recipe",
  origin: `http://localhost:${port}`,
  appStoreUrl: process.env.APP_STORE_URL,
  appId: "7GZKY29XJH.com.maxwellkendall.aicoach",
};

const wins: Record<string, Win> = {
  bench: {
    kind: "pr", name: "Max Kendall", date: "2026-10-08", metric: "Bench Press", unit: "lb", value: 205, previous: 190,
    trend: [175, 180, 180, 185, 190, 190, 195, 205], showNumbers: true, style: "dark", invite: "X7K2PQ", program: "strength12",
  },
  private: {
    kind: "pr", name: "Max Kendall", date: "2026-10-08", metric: "Back Squat", unit: "lb", value: 245, previous: 225,
    trend: [205, 215, 215, 225, 235, 245], showNumbers: false, style: "paper", invite: "X7K2PQ",
  },
  goal: {
    kind: "milestone", name: "Max Kendall", date: "2026-10-01", metric: "Bench 225", unit: "lb", value: 170, target: 225, percent: 75,
    showNumbers: true, style: "dark", program: "strength12",
  },
  streak: { kind: "streak", name: "Jo Rivera", date: "2026-10-05", metric: "Training", unit: "weeks", value: 6, showNumbers: true, style: "paper", invite: "X7K2PQ" },
};

const recaps: Record<string, Recap> = {
  week6: {
    name: "Max Kendall", week: 6, weeks: 12, phase: "build", sessions: { done: 3, planned: 3 }, bests: 2, showNumbers: true,
    lifts: [
      { metric: "Bench Press", from: 190, to: 205, unit: "lb" },
      { metric: "Back Squat", from: 225, to: 245, unit: "lb" },
      { metric: "Bent Over Row", from: 115, to: 125, unit: "lb" },
    ],
    invite: "X7K2PQ", program: "strength12",
  },
  done: {
    name: "Jo Rivera", week: 12, weeks: 12, phase: "peak", sessions: { done: 44, planned: 48 }, bests: 11, showNumbers: false,
    lifts: [
      { metric: "Deadlift", from: 315, to: 365, unit: "lb" },
      { metric: "Overhead Press", from: 95, to: 110, unit: "lb" },
    ],
    invite: "X7K2PQ",
  },
};

const programs: Record<string, Program> = {
  strength12: {
    name: "Bench 225 by December", by: "Max Kendall", weeks: 12, days: 3, equipment: "Full gym",
    goals: ["Bench 225 lb", "Squat 275 lb"],
    phases: [
      { phase: "base", from: 1, to: 4, focus: "Volume and technique: higher reps to build work capacity and pulling strength.", mainLifts: ["Back Squat", "Bench Press", "Bent Over Row"], mainReps: 8 },
      { phase: "build", from: 5, to: 8, focus: "Heavier squat and bench, with rows kept for back balance.", mainLifts: ["Back Squat", "Bench Press", "Bent Over Row"], mainReps: 5 },
      { phase: "peak", from: 9, to: 12, focus: "The heaviest loads at low reps, before the December test.", mainLifts: ["Back Squat", "Bench Press"], mainReps: 3 },
    ],
    sampleWeek: [
      { day: "Monday", title: "Squat and bench", items: ["Back Squat 4 × 8", "Bench Press 4 × 8", "Single-Arm Row 3 × 12", "Plank 3 × 50 s"] },
      { day: "Wednesday", title: "Row, hinge and pull", items: ["Bent Over Row 4 × 8", "Deadlift 3 × 8", "Pull-up 4 × 6", "Farmer Carry 3 × 30 m"] },
      { day: "Friday", title: "Squat, lunge and push", items: ["Back Squat 4 × 8", "Dumbbell Bench 4 × 12", "Lunges 3 × 12", "Dead Bug 3 × 10"] },
    ],
    invite: "X7K2PQ",
  },
};

const invites: Record<string, Invite> = {
  X7K2PQ: {
    group: "Dawn Patrol", by: "Max Kendall", members: ["Max", "Jo", "Priya", "Sam", "Lee", "Ana", "Theo"],
    recent: ["Max set a bench press best", "Jo trained 6 weeks straight", "Priya is 50% of the way to her squat goal"],
  },
};

const store: Store = {
  win: async (id) => wins[id],
  recap: async (id) => recaps[id],
  program: async (id) => programs[id],
  invite: async (code) => invites[code],
};

createServer(async (req, res) => {
  const path = new URL(req.url ?? "/", site.origin).pathname.replace(/\/+$/, "") || "/";
  if (path === "/samples") {
    const links = [
      ...Object.keys(wins).map((id) => `/w/${id}`), ...Object.keys(recaps).map((id) => `/r/${id}`),
      ...Object.keys(programs).map((id) => `/p/${id}`), ...Object.keys(invites).map((code) => `/join/${code}`),
      "/w/missing", "/.well-known/apple-app-site-association",
    ];
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(`<!doctype html><meta name="viewport" content="width=device-width"><title>Samples</title>
      <body style="font:17px/1.8 -apple-system,sans-serif;padding:24px"><h1>Share page samples</h1>${links.map((l) => `<a href="${l}">${l}</a>`).join("<br>")}`);
    return;
  }
  const page = await route(path, store, site);
  res.writeHead(page.status, { "content-type": page.type });
  res.end(page.body);
}).listen(port, () => console.log(`Share pages on http://localhost:${port}/samples`));
