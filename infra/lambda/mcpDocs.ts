import { esc, layout, type Site } from "./sharePages.ts";

/**
 * FIT-236: the connector's public documentation at /docs, which Claude's directory asks for. The MCP server serves it,
 * so its tools and prompts are listed from the same definitions agents get, and can't drift from them.
 */

type Tool = {
  name: string; title: string; description: string;
  annotations: { readOnlyHint?: boolean; destructiveHint?: boolean; openWorldHint?: boolean };
  inputSchema: { properties?: Record<string, unknown> };
};
type Prompt = { name: string; title: string; description: string };

/** Stored as a proposal, so they count as reads; apply makes them real. */
const PROPOSE = ["propose_session", "propose_week", "clear_day", "apply", "undo"];
const COACHING = ["list_clients", "roster_review", "invite_client"];

const SAYS = [
  ["Who needs me this week?", "Your roster, those who need you first: pain or an unanswered note, missed sessions, RPE 9 on a main lift, a stalled lift, and whose next week isn't written."],
  ["Mike's knee is sore and his squat has stalled. Rebuild next week.", "Claude reads his logs and notes, swaps around the knee, adjusts the loads, and shows you the week before saving it."],
  ["Write Sara a 12-week program to her meet in March.", "Phases, deloads and a test week laid out to the date, then the first weeks planned from her maxes."],
  ["Here's Jen's program from my spreadsheet.", "Paste or attach a sheet, CSV, PDF or screenshot: it becomes her program in your numbers, percentages, RPE and supersets included."],
  ["Invite a new client.", "A link and a 6-character code to send them. They open it in the free Barbrabell app and allow you to coach them."],
  ["Set me up.", "Training yourself: Claude asks your goals, schedule, equipment and maxes, then writes your program."],
];

function kind(t: Tool) {
  if (t.annotations.openWorldHint) return "Makes a public link";
  if (t.annotations.readOnlyHint) return PROPOSE.includes(t.name) ? "Proposes a change" : "Reads";
  return t.annotations.destructiveHint ? "Changes or deletes data" : "Saves data";
}

function toolList(list: Tool[]) {
  return `<dl class="tools">${list.map((t) => `
    <dt><code>${esc(t.name)}</code> ${esc(t.title)} <span class="tag">${kind(t)}</span>${t.inputSchema.properties?.client ? `<span class="tag">Coaches: for a client</span>` : ""}</dt>
    <dd>${esc(t.description)}</dd>`).join("")}
  </dl>`;
}

export function docsPage(site: Site, mcpUrl: string, tools: Tool[], prompts: Prompt[]) {
  const coaching = tools.filter((t) => COACHING.includes(t.name));
  const changes = PROPOSE.map((n) => tools.find((t) => t.name === n)!).filter(Boolean);
  const reads = tools.filter((t) => t.annotations.readOnlyHint && !PROPOSE.includes(t.name) && !COACHING.includes(t.name));
  const writes = tools.filter((t) => !t.annotations.readOnlyHint && !PROPOSE.includes(t.name) && !COACHING.includes(t.name));
  return layout(site, {
    title: `${site.appName} connector`,
    description: `How the ${site.appName} MCP connector works: connecting, signing in, what it can read and change, every tool, and your data.`,
    path: "/docs",
    body: `
      <section class="hero left">
        <p class="eyebrow">Documentation</p>
        <h1>The ${esc(site.appName)} connector</h1>
        <p class="lede">${esc(site.appName)} is an MCP server for strength training. Coaches use it in Claude to write and change their clients' programs from what the clients logged; clients follow along in the free ${esc(site.appName)} iPhone app. People training themselves use it the same way, for free.</p>
      </section>

      <section class="block doc">
        <h2>Connect</h2>
        <p>The server's address:</p>
        <button class="code url" type="button" data-copy="${esc(mcpUrl)}" aria-label="Copy the connector address">${esc(mcpUrl)}<small>Copy</small></button>
        <ol>
          <li>In Claude, open Settings › Connectors and add ${esc(site.appName)}: from the directory, or with Add custom connector and the address above.</li>
          <li>Choose Connect and sign in with Apple or Google. A first sign-in makes a free account; use the same one as in the app.</li>
          <li>Say “Show me my clients”, or “Set me up” if you're training yourself.</li>
        </ol>
        <p>Once added, it's in Claude on the web, the desktop app and your phone. Other MCP clients connect at the same address: streamable HTTP, with OAuth 2.0 (authorization code with PKCE, dynamic client registration, rotating refresh tokens). Access tokens last an hour and refresh tokens 90 days; disconnect in your client to end it sooner.</p>
      </section>

      <section class="block doc">
        <h2>What to ask</h2>
        <dl class="says-list">${SAYS.map(([say, what]) => `<dt>“${esc(say)}”</dt><dd>${esc(what)}</dd>`).join("")}</dl>
      </section>

      <section class="block doc">
        <h2>How changes work</h2>
        <ul>
          <li><b>Nothing changes until you agree.</b> Claude proposes a session or a week, shows it to you, and saves it with apply once you say yes. Plan rules are checked first: a deload week stays light, a travel week uses what's on hand, no one's weekly sets run past their ceiling.</li>
          <li><b>Undo.</b> An applied day can be put back within 14 days, unless it's been logged since.</li>
          <li><b>On the client's phone</b> at the app's next sync.</li>
          <li><b>Deleting a log</b> asks first and can't be undone. <b>Sharing</b> makes a public link, only when asked.</li>
        </ul>
      </section>

      <section class="block doc">
        <h2>Coaching</h2>
        <ul>
          <li>Coaching is free, with any number of clients, on the dashboard at <a href="/app">${esc(new URL(mcpUrl).host)}/app</a>. Connecting and training yourself are free too.</li>
          <li>Here, reading a client, notes, listing clients and inviting are free. Planning and changing a client's training (proposals, apply and undo, their program, goals and swaps) and the roster and weekly reviews are ${esc(site.appName)} Pro, from Billing on the dashboard. A sample client takes every tool, so you can try Pro first.</li>
          <li>Invite a client with a link or code (from Claude or the dashboard). They accept in the free app; they need no AI account.</li>
          <li>You can read a client's training and plan it: their goals, profile, program, sessions, logs and notes. Logging and sharing stay theirs.</li>
          <li>Clients can stop sharing with you any time in the app. You can stop coaching one on the dashboard.</li>
        </ul>
      </section>

      <section class="block doc">
        <h2>Tools</h2>
        <p>${tools.length} tools. Read tools run without asking; Claude asks before the others, as your settings say. Tools marked “Coaches: for a client” take a client's name to act on their training instead of your own.</p>
        <h3>Your clients</h3>${toolList(coaching)}
        <h3>Reading</h3>${toolList(reads)}
        <h3>Changing the plan</h3>${toolList(changes)}
        <h3>Logging and saving</h3>${toolList(writes)}
      </section>

      <section class="block doc">
        <h2>Prompts</h2>
        <p>Routines a client lists for you to pick, such as Claude's + menu.</p>
        <dl class="tools">${prompts.map((p) => `<dt><code>${esc(p.name)}</code> ${esc(p.title)}</dt><dd>${esc(p.description)}</dd>`).join("")}</dl>
      </section>

      <section class="block doc">
        <h2>Your data</h2>
        <ul>
          <li>What's kept: your name and email from sign-in, and the training you or your coach enter: goals, profile (age, weight, schedule, equipment, areas to go easy on), program, sessions, logged sets and runs, body weight, sleep, meals, and notes.</li>
          <li>Where: ${esc(site.appName)}'s own servers on AWS in the US. It isn't sold, used for ads, or sent anywhere else by the connector.</li>
          <li>Who sees it: you, and coaches you've accepted. A shared link shows what you chose to share.</li>
          <li>Deleting your account (in the app under You › Account, or by email) deletes it.</li>
        </ul>
        <p>The <a href="/privacy">privacy policy</a> and <a href="/terms">terms</a> have the details.</p>
      </section>

      <section class="block doc">
        <h2>Help</h2>
        <p>See <a href="/support">support</a>, or email us from there. A person reads every message.</p>
      </section>`,
  });
}
