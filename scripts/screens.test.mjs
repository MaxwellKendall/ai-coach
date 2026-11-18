import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { coverage, inventory, mask, parseExcludes, parseMarks } from "./screens-lib.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));

const app = {
  path: "App/RootView.swift",
  source: `
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Clients", systemImage: "person.2", value: AppTab.clients) { ClientsScreen() }
            Tab("Today", systemImage: "figure", value: AppTab.today) { TodayScreen() }
            Tab(groupsTab.title, systemImage: "person.2", value: AppTab.groups) { NavigationStack { GroupsScreen() } }
        }
        .tint(RootView.accent)
        .sheet(isPresented: $paywall) { PaywallView(plan: .lifter) }
        .fullScreenCover(isPresented: $welcoming) { WelcomeView() }
    }
}`,
};
const today = {
  path: "Features/Today/TodayScreen.swift",
  source: `
struct TodayScreen: View {
    var body: some View {
        // NavigationLink { NotAScreen() } in a comment is ignored.
        List {
            DayCard()
            NavigationLink(value: day) { Text("Day") }
            if empty { ContentUnavailableView("No wins yet", systemImage: "trophy") }
        }
        .sheet(item: $sheet, content: sheetView)
        .sheet(isPresented: $you) { YouScreen().tint(RootView.accent) }
        .alert("Couldn’t do that", isPresented: $failed) { }
        .navigationTitle("Today")
    }
    @ViewBuilder private func sheetView(_ sheet: Sheet) -> some View {
        switch sheet { case .move: MoveSheet() }
    }
}
struct DayCard: View {
    var body: some View { Text("x").sheet(isPresented: $howTo) { HowToSheet() } }
}`,
};
const you = {
  path: "Features/Today/YouScreen.swift",
  source: `
struct YouScreen: View {
    var body: some View {
        NavigationLink { AccountView() } label: { Text("Account") }
        .sheet(item: $plan) { plan in PaywallView(plan: plan) }
    }
}
struct AccountView: View { var body: some View { Text("") } }`,
};
const rest = {
  path: "Features/Other.swift",
  source: `
struct ClientsScreen: View { var body: some View { List {}.sheet(isPresented: $you) { YouScreen() } } }
struct GroupsScreen: View { var body: some View { Text("") } }
struct WelcomeView: View { var body: some View { Text("") } }
struct PaywallView: View { var body: some View { Text("") } }
struct MoveSheet: View { var body: some View { Text("") } }
struct HowToSheet: View { var body: some View { Text("") } }
struct NotAScreen: View { var body: some View { Text("") } }
struct Orphan: View { var body: some View { Text("").sheet(isPresented: $x) { Lonely() } } }
struct Lonely: View { var body: some View { Text("") } }`,
};

const byId = () => new Map(inventory([app, today, you, rest]).screens.map((s) => [s.id, s]));

test("mask blanks comments and strings but keeps offsets", () => {
  const source = 'let a = "{ X() }" // Y()\n/* Z() */ b';
  const masked = mask(source);
  assert.equal(masked.length, source.length);
  assert.ok(!/X\(|Y\(|Z\(/.test(masked));
  assert.ok(masked.endsWith(" b"));
});

test("tabs give their roles to what they reach; RootView's own sheets are everyone's", () => {
  const s = byId();
  assert.deepEqual(s.get("tab.Clients").roles, ["coach"]);
  assert.deepEqual(s.get("tab.Today").roles, ["solo", "client"]);
  assert.deepEqual(s.get("MoveSheet").roles, ["solo", "client"], "content: sheetView builds the sheet");
  assert.deepEqual(s.get("HowToSheet").roles, ["solo", "client"], "a sheet in a contained view belongs to its screen");
  assert.deepEqual(s.get("YouScreen").roles, ["solo", "client", "coach"], "You opens from Today and from Clients");
  assert.deepEqual(s.get("AccountView").roles, ["solo", "client", "coach"]);
  assert.equal(s.get("AccountView").kind, "push");
  assert.deepEqual(s.get("WelcomeView").roles, ["solo", "client", "coach"]);
  assert.equal(s.get("WelcomeView").kind, "cover");
});

test("each paywall is its own screen, for the roles that can buy it", () => {
  const s = byId();
  assert.deepEqual(s.get("PaywallView.lifter").roles, ["solo"]);
  assert.deepEqual(s.get("PaywallView.coach").roles, ["coach"], "You's PaywallView(plan: plan) can be Coach Pro, for a coach");
  assert.ok(!s.has("PaywallView"));
});

test("hidden tabs, unreachable views, static members and comments are not required screens", () => {
  const s = byId();
  assert.deepEqual(s.get("tab.Groups").roles, []);
  assert.match(s.get("tab.Groups").unreachable, /Pilot\.simple/);
  assert.deepEqual(s.get("Lonely").roles, []);
  assert.ok(!s.has("RootView"), "RootView.accent is not a presented RootView");
  assert.ok(!s.has("NotAScreen"));
  assert.ok(!s.has("DayCard"), "a contained view is not a screen");
});

test("empty states and alerts are screens of the view that shows them", () => {
  const s = byId();
  assert.deepEqual(s.get("TodayScreen.empty.no-wins-yet").roles, ["solo", "client"]);
  assert.equal(s.get("TodayScreen.alert.couldnt-do-that").title, "Couldn’t do that");
});

test("the inventory is deterministic", () => {
  assert.deepEqual(inventory([app, today, you, rest]), inventory([app, today, you, rest]));
});

test("coverage lists each missing screen once, under the roles that can reach it", () => {
  const inv = inventory([app, today, you, rest]);
  const marks = parseMarks("client tab.Today\ncoach tab.Clients\nclient YouScreen\ncoach WelcomeView\nsolo Nope\n");
  const excludes = parseExcludes("# comment\nHowToSheet  # not in the demo\nGone  # removed screen\n");
  const result = coverage(inv, marks, excludes);
  assert.equal(result.ok, false);
  assert.deepEqual(result.unknown, ["solo Nope"]);
  assert.deepEqual(result.staleExcludes, ["Gone"]);
  assert.ok(result.missing["solo, client"].includes("MoveSheet"));
  assert.ok(result.missing.solo.includes("PaywallView.lifter"));
  assert.ok(result.missing.coach.includes("PaywallView.coach"));
  assert.equal(new Set(Object.values(result.missing).flat()).size, Object.values(result.missing).flat().length);
  assert.ok(!Object.values(result.missing).flat().includes("HowToSheet"), "excluded");
  assert.ok(!Object.values(result.missing).flat().includes("YouScreen"), "shown by the client");
  assert.ok(!Object.values(result.missing).flat().includes("tab.Groups"), "hidden tab");
});

test("a screen shown by a role that can't reach it doesn't count", () => {
  const inv = inventory([app, today, you, rest]);
  const result = coverage(inv, parseMarks("coach tab.Today\n"));
  assert.ok(result.missing["solo, client"].includes("tab.Today"));
});

test("TKL-460: coverage for some roles owes every screen any of them can reach, shared ones too", () => {
  const inv = inventory([app, today, you, rest]);
  const owed = coverage(inv, [], new Map(), { roles: ["client", "coach"] });
  assert.equal(owed.ok, false);
  assert.ok(owed.missing.coach.includes("PaywallView.coach"));
  assert.ok(owed.missing["solo, client"].includes("tab.Today"), "a screen a client shares with solo is still owed");
  assert.equal(owed.missing.solo, undefined, "a solo-only screen isn't owed for client and coach");
  // The verifier's probe: a coach-only screen shown and an unshown solo/client screen must not pass.
  const coachOnly = owed.missing.coach.map((id) => ({ role: "coach", id }));
  const probe = coverage(inv, coachOnly, new Map(), { roles: ["client", "coach"] });
  assert.equal(probe.ok, false);
  assert.ok(probe.missing["solo, client"].includes("tab.Today"));
  // Every owed screen shown by a role that can reach it: passes.
  const all = Object.entries(owed.missing).flatMap(([roles, ids]) => ids.map((id) => ({ role: roles.split(", ").at(-1), id })));
  const passed = coverage(inv, all, new Map(), { roles: ["client", "coach"] });
  assert.equal(passed.ok, true, JSON.stringify(passed.missing));
  assert.equal(passed.shown, passed.required);
});

test("TKL-460: a shared screen the solo chapter showed counts for the client", () => {
  const inv = inventory([app, today, you, rest]);
  const owed = coverage(inv, [], new Map(), { roles: ["client"] });
  const solo = owed.missing["solo, client"].map((id) => ({ role: "solo", id }));
  const result = coverage(inv, solo, new Map(), { roles: ["client"] });
  assert.equal(result.missing["solo, client"], undefined, JSON.stringify(result.missing));
});

test("TKL-460: screen-coverage.mjs --roles checks those roles, and --also adds another chapter's marks", () => {
  const inv = JSON.parse(readFileSync(new URL("../appstore/review/screens.json", import.meta.url), "utf8"));
  const excludes = parseExcludes(readFileSync(new URL("../appstore/review/coverage-exclude.txt", import.meta.url), "utf8"));
  const owed = inv.screens.filter((s) => s.roles.length && !excludes.has(s.id));
  const coachOnly = owed.filter((s) => s.roles.every((r) => r === "coach")).map((s) => `coach ${s.id}`);
  const shared = owed.filter((s) => s.roles.includes("solo") && s.roles.includes("client")).map((s) => `solo ${s.id}`);
  const dir = mkdtempSync(join(tmpdir(), "cov-"));
  const marks = join(dir, "marks.txt");
  const solo = join(dir, "solo.txt");
  writeFileSync(marks, coachOnly.join("\n") + "\n");
  writeFileSync(solo, shared.join("\n") + "\n");
  const cov = (...args) => spawnSync("node", ["scripts/screen-coverage.mjs", ...args], { cwd: root, encoding: "utf8" });
  const coachOnlyRun = cov(marks, "--roles", "client,coach");
  assert.equal(coachOnlyRun.status, 1, "coach-only marks don't cover the client");
  assert.match(coachOnlyRun.stdout, /for client, coach/);
  const both = cov(marks, "--roles", "client,coach", "--also", solo);
  assert.equal(both.status, 0, both.stdout + both.stderr);
  assert.equal(cov(marks, "--also", join(dir, "missing.txt")).status, 2, "a missing --also file is an error, not a silent pass");
});

test("the committed appstore/review/screens.json matches the code", () => {
  const run = spawnSync("node", ["scripts/screen-inventory.mjs", "--check"], { cwd: root, encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
});
