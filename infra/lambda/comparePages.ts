import { esc, html, layout, START, type Page, type Site } from "./sharePages.ts";

/**
 * FIT-244: why Barbrabell, against every tool a coach might weigh it with. One page per tool at /compare/{slug},
 * a hub at /compare, and the files search engines and AI assistants read (robots.txt, sitemap.xml, llms.txt).
 * Each page says where the other tool is better too: a fair comparison is the one people link to and assistants quote.
 * Prices are from each vendor's own pricing page on CHECKED unless the source says otherwise; recheck before changing them.
 */

export const CHECKED = "October 24, 2026";
const ISO = "2026-10-24";

export interface Rival {
  slug: string;
  name: string;
  kind: "Coach platform" | "AI coach tool" | "Gym software" | "Do it yourself" | "Consumer app";
  /** What it is, in one sentence. */
  what: string;
  /** Its price, as its page gives it. */
  price: string;
  /** Monthly price for 10, 20 and 40 clients, where its page gives one. */
  at?: [string, string, string];
  ai: string;
  clients: string;
  /** Where it's better than Barbrabell. Every page has some. */
  better: string[];
  /** Where Barbrabell is better than it. */
  worse: string[];
  pickThem: string;
  pickUs: string;
  sources: { label: string; url: string }[];
}

const US = {
  price: "$19.99 a month or $199 a year, any number of clients. Clients are free.",
  ai: "The Claude or ChatGPT you already use writes and changes each client's week from what they logged. You say apply and it's on their phone, with undo.",
  clients: "A free iPhone app: today's session, sets to check off, progress. No AI account needed.",
};

export const rivals: Rival[] = [
  {
    slug: "trainera",
    name: "Trainera",
    kind: "AI coach tool",
    what: "An all-in-one coaching platform (plans, check-ins, messages, payments, courses, community) with an MCP server for Claude and ChatGPT.",
    price: "Free for 3 clients; Starter $19.99 a month for 10, Pro $49.99 for 30, Business $99 for 75. A platform fee of 8% down to 1% on client payments.",
    at: ["$19.99", "$49.99", "$99"],
    ai: "An in-app assistant capped at 20 requests a month on Starter and 50 on Pro, plus an MCP server that drafts plans. Drafts are assigned to the client inside Trainera.",
    clients: "A free app on iPhone, Android, web and watches, with food logging and messages.",
    better: [
      "Far more in one place: payments, courses, live streams, a community feed, recipes and messaging.",
      "Client apps on Android, the web and watches, not just iPhone.",
      "Nutrition plans and food logging built in.",
      "A free plan for up to 3 clients.",
    ],
    worse: [
      "One price with no client cap: a coach with 20 clients pays $19.99, not $49.99.",
      "No AI request cap. The model is the Claude or ChatGPT you already pay for.",
      "Nothing to finish in a second app: say apply in Claude and the week is on the client's phone, with undo.",
      "Fewer screens to learn. The coach works in a conversation; the client sees today's session and checks off sets.",
    ],
    pickThem: "you want payments, courses, community and nutrition in one platform, or your clients use Android.",
    pickUs: "you program strength clients, you already work in Claude or ChatGPT, and you want the week on the client's phone without leaving the chat.",
    sources: [{ label: "Trainera pricing", url: "https://trainera.fit/pricing" }],
  },
  {
    slug: "truecoach",
    name: "TrueCoach",
    kind: "Coach platform",
    what: "One of the most used online coaching apps: a workout builder, client tracking, messaging and payments.",
    price: "Starter $26.34 a month for 5 active clients, Standard $57.99 for 20, Pro $136.99 for 50, as its pricing page lists them. Over 50 by email.",
    at: ["$57.99", "$57.99", "$136.99"],
    ai: "No assistant that writes programs from client logs; you build workouts in its builder.",
    clients: "A client app on iPhone and Android with messaging, video and nutrition tracking through MyFitnessPal.",
    better: [
      "Mature and widely used, with a large video library, messaging and payments.",
      "Client apps on iPhone and Android, and wearable data on Standard and Pro.",
      "A custom-branded app on Standard and up.",
    ],
    worse: [
      "$19.99 for any number of clients, against $57.99 for 20 and $136.99 for 50.",
      "The AI writes the week for you from each client's logged sets, injuries and equipment; in TrueCoach you build it by hand.",
      "Rules live in code: plans stay inside limits for age, equipment and injuries, whoever writes them.",
      "Bringing a TrueCoach program over is a paste: Claude reads the sheet and lays it out for each client.",
    ],
    pickThem: "you want an established all-round platform with payments, video and a branded app, and you're happy building programs by hand.",
    pickUs: "programming is where your hours go and you'd rather Claude drafted each week from the logs while you approve it.",
    sources: [{ label: "TrueCoach pricing", url: "https://truecoach.co/pricing/" }],
  },
  {
    slug: "trainerize",
    name: "Trainerize",
    kind: "Coach platform",
    what: "ABC Trainerize: a coaching app for trainers and studios with workouts, habits, nutrition, payments and branded apps.",
    price: "Free for 1 client, Grow $9 a month for 2, Pro from $23 for 5 and more as seats grow. Nutrition $20–45, payments $10 and video $10 a month extra; a branded app is $169 to set up.",
    ai: "An AI workout builder inside the app.",
    clients: "A client app on iPhone and Android, which can carry your brand.",
    better: [
      "A big feature set: habits, nutrition coaching, video, payments, studio plans for gyms.",
      "Client apps on iPhone and Android, and branded apps.",
      "Long track record and integrations.",
    ],
    worse: [
      "One flat $19.99 with nothing extra to add on; Trainerize's price climbs with seats and add-ons.",
      "The AI works from what each client actually logged and changes next week from it, not just a template.",
      "You work in the assistant you already use instead of learning another builder.",
    ],
    pickThem: "you run a studio or want nutrition, payments and a branded app in one place.",
    pickUs: "you're a solo strength coach who wants the programming done in Claude or ChatGPT at one price.",
    sources: [{ label: "Trainerize pricing", url: "https://www.trainerize.com/pricing/" }],
  },
  {
    slug: "everfit",
    name: "Everfit",
    kind: "Coach platform",
    what: "A coaching platform with a workout builder, automation (Autoflow), on-demand content and meal plans as add-ons.",
    price: "Free for 5 clients; Pro $29 a month for 10, $49 for 20, $95 for 50 (less billed yearly). Automation from $29, meal plans $39 and payments $9 a month extra.",
    at: ["$29", "$49", "$95"],
    ai: "An AI workout builder, AI reply drafts for client messages, and AI meal plans as a paid add-on.",
    clients: "A free client app on iPhone and Android.",
    better: [
      "A free plan for up to 5 clients.",
      "Automation, on-demand collections and meal plans when you pay for the add-ons.",
      "Client apps on iPhone and Android.",
    ],
    worse: [
      "$19.99 for any number of clients, against $49 for 20 and $95 for 50 before add-ons.",
      "The model reads every logged set, note and sore knee and proposes the next week; you approve with one word.",
      "No add-ons to price out: what's there is all included.",
    ],
    pickThem: "you want a free start for a few clients, automation and meal plans.",
    pickUs: "you want programming written from each client's logs, in Claude or ChatGPT, at one flat price.",
    sources: [{ label: "Everfit pricing", url: "https://everfit.io/pricing/" }],
  },
  {
    slug: "trainheroic",
    name: "TrainHeroic",
    kind: "Coach platform",
    what: "Strength and conditioning software for coaches and teams, with a marketplace for selling programs.",
    price: "$9.99 a month for 1 athlete, $34.99 for 15, $44.99 for 25, $74.99 for 50, up to $399.99 for 1,000.",
    at: ["$34.99", "$44.99", "$74.99"],
    ai: "No assistant that writes programs from athlete logs.",
    clients: "An athlete app on iPhone and Android, built for teams.",
    better: [
      "Built for teams and S&C programs, with a marketplace to sell programs to many athletes.",
      "Athlete apps on iPhone and Android.",
      "Scales to hundreds of athletes.",
    ],
    worse: [
      "$19.99 for any number of clients, against $44.99 for 25.",
      "Each client's week is written for them from their own maxes and logs, not one team program for everyone.",
      "You program by talking to Claude or ChatGPT instead of building in a spreadsheet-style editor.",
    ],
    pickThem: "you coach teams or sell one program to many athletes.",
    pickUs: "you coach individuals and want each one's program fitted to what they actually lifted.",
    sources: [{ label: "TrainHeroic pricing", url: "https://www.trainheroic.com/pricing/" }],
  },
  {
    slug: "hevy-coach",
    name: "Hevy Coach",
    kind: "Coach platform",
    what: "The coach side of Hevy, the popular workout logger: you program, clients log in the Hevy app.",
    price: "From $25 a month for up to 10 clients, priced by client bracket above that, monthly only.",
    ai: "No assistant that writes programs from client logs.",
    clients: "The Hevy app on iPhone and Android, with Hevy Pro free for your clients.",
    better: [
      "Clients get Hevy, a polished logger many lifters already use, on iPhone and Android.",
      "A 30-day free trial with no card.",
    ],
    worse: [
      "$19.99 for any number of clients.",
      "Claude or ChatGPT writes and adjusts each week from the logs; in Hevy Coach you write it.",
      "A dashboard that flags pain notes, very hard sessions and stalled lifts across the roster.",
    ],
    pickThem: "your clients already love Hevy and you're happy writing programs yourself.",
    pickUs: "you want the program writing and the roster review done with you in Claude or ChatGPT.",
    sources: [{ label: "Hevy Coach pricing", url: "https://hevycoach.com/pricing/" }],
  },
  {
    slug: "assistant-coach",
    name: "Assistant Coach",
    kind: "AI coach tool",
    what: "A UK coaching platform with check-ins, plan building, a branded client app, a coaching website and a built-in assistant.",
    price: "Free for 5 clients; Pro £59 a month, or £29.50 a month billed yearly.",
    ai: "A built-in assistant, and on Pro a read-only connection to ChatGPT and Claude: they can read but not create or change plans.",
    clients: "A branded client app.",
    better: [
      "A full platform with a coaching website and branded client app.",
      "A free plan for up to 5 clients.",
    ],
    worse: [
      "Claude and ChatGPT can write here, not just read: propose the week, apply it, undo it.",
      "$19.99 a month with no client cap.",
      "Simpler: the conversation is the coach's whole interface.",
    ],
    pickThem: "you want a branded app and website, and only need the assistant to read your data.",
    pickUs: "you want the assistant to actually program your clients.",
    sources: [{ label: "Assistant Coach", url: "https://assistantcoach.co" }],
  },
  {
    slug: "coachrx",
    name: "CoachRx",
    kind: "Coach platform",
    what: "Coaching software from OPEX for assessment-led programming, with an AI assistant, RxBot.",
    price: "About $25 a month for 1–5 clients and $67 for 6–50, per Capterra's listing; CoachRx doesn't publish a price page we could check.",
    ai: "RxBot, an AI assistant inside the app.",
    clients: "A client app on iPhone and Android.",
    better: [
      "A deep, assessment-led coaching method behind it, and coach education from OPEX.",
      "Client apps on iPhone and Android.",
    ],
    worse: [
      "$19.99 for any number of clients.",
      "Use the strongest model you already pay for, not a built-in bot.",
      "Say apply and the change is on the client's phone, with undo.",
    ],
    pickThem: "you follow the OPEX method and want software built around it.",
    pickUs: "you want your own programming, drafted with Claude or ChatGPT from each client's logs.",
    sources: [{ label: "CoachRx on Capterra", url: "https://www.capterra.com/p/253158/CoachRx/pricing/" }],
  },
  {
    slug: "pt-distinction",
    name: "PT Distinction",
    kind: "Coach platform",
    what: "Online coaching software with programs, nutrition, automations and a branded client app.",
    price: "Three plans from about $19.90 to $89.90 a month, per Capterra's 2026 listing.",
    ai: "No assistant that writes programs from client logs.",
    clients: "A client app on iPhone and Android, brandable.",
    better: [
      "Nutrition, automations and a branded app.",
      "Client apps on iPhone and Android.",
    ],
    worse: [
      "Programs drafted from each client's logs in Claude or ChatGPT.",
      "One price with no client tiers.",
      "Fewer screens for the client: today's session and the sets.",
    ],
    pickThem: "you want nutrition and automations in a branded app.",
    pickUs: "you want strength programming done with you in the chat.",
    sources: [{ label: "PT Distinction on Capterra", url: "https://www.capterra.com/p/141155/PT-Distinction/pricing/" }],
  },
  {
    slug: "my-pt-hub",
    name: "My PT Hub",
    kind: "Coach platform",
    what: "Personal trainer software with workouts, nutrition, payments and booking.",
    price: "From about $22.50 a month, per Capterra's listing.",
    ai: "No assistant that writes programs from client logs.",
    clients: "A client app on iPhone and Android.",
    better: [
      "Booking, payments and nutrition built in.",
      "Client apps on iPhone and Android.",
    ],
    worse: [
      "Programs drafted from each client's logs in Claude or ChatGPT.",
      "No client cap at $19.99.",
    ],
    pickThem: "you run in-person sessions and need booking and payments.",
    pickUs: "you program remote strength clients and want the writing done with you.",
    sources: [{ label: "My PT Hub", url: "https://www.mypthub.net" }],
  },
  {
    slug: "exercise-com",
    name: "Exercise.com",
    kind: "Gym software",
    what: "Business software for gyms and fitness companies: booking, payments, branded apps and programs.",
    price: "From about $239 a month, per Capterra's listing.",
    ai: "No assistant that writes programs from client logs.",
    clients: "Your own branded app.",
    better: [
      "Runs a whole gym: booking, memberships, payments and a branded app.",
      "Built for teams of trainers.",
    ],
    worse: [
      "$19.99 a month instead of about $239.",
      "Set up in minutes: connect Claude, invite a client.",
      "Programs drafted from each client's logs.",
    ],
    pickThem: "you run a gym and need memberships, booking and a branded app.",
    pickUs: "you're a coach who needs programming and client tracking, not gym management.",
    sources: [{ label: "Exercise.com on Capterra", url: "https://capterra.com/p/152284/exercise-com/pricing/" }],
  },
  {
    slug: "spreadsheets",
    name: "Google Sheets and Excel",
    kind: "Do it yourself",
    what: "The coach's spreadsheet: one tab per client, shared by link or exported to PDF.",
    price: "Free, or part of what you already pay for.",
    ai: "Whatever you paste into ChatGPT or Claude yourself.",
    clients: "A shared sheet on their phone.",
    better: [
      "Free and endlessly flexible.",
      "Nothing for clients to install.",
    ],
    worse: [
      "Clients check off sets in an app made for the gym, not a sheet on a phone.",
      "What they logged comes back to you; no chasing.",
      "Claude reads every log and drafts next week; no copying numbers between tabs.",
      "Moving over is a paste: give Claude the sheet and it lays it out for each client.",
    ],
    pickThem: "you have a handful of clients and the sheet works.",
    pickUs: "you spend hours a week rebuilding sheets and chasing logs.",
    sources: [],
  },
  {
    slug: "chatgpt-or-claude",
    name: "ChatGPT or Claude on their own",
    kind: "Do it yourself",
    what: "Programming in a chat, then copying it into a sheet, a message or another app.",
    price: "What you already pay for the assistant.",
    ai: "The best models there are, with no memory of your clients beyond what you paste in.",
    clients: "Whatever you send them.",
    better: [
      "Nothing new to buy or set up.",
      "Full freedom over the prompt.",
    ],
    worse: [
      "The assistant reads each client's real logs, maxes and injuries instead of what you paste.",
      "Say apply and the week is on the client's phone; no copying.",
      "Rules in code check every plan against age, equipment and injuries.",
      "Ready-made routines: set up a client, plan next week, weekly review, roster review.",
    ],
    pickThem: "you only want ideas and do the rest by hand.",
    pickUs: "you already program with AI and want it connected to your clients.",
    sources: [],
  },
  {
    slug: "ladder",
    name: "Ladder",
    kind: "Consumer app",
    what: "A strength app where one well-known coach writes a week for everyone on a team, delivered as follow-along video.",
    price: "About $30 a month for Pro and $45 for Elite, with no free tier. Paid by the athlete.",
    ai: "Not an AI programmer: coaches write team programs.",
    clients: "An iPhone app with polished follow-along video.",
    better: [
      "Celebrity coaches, a big video library and a brand people know.",
      "For a lifter without a coach, a cheap way to follow a good program.",
    ],
    worse: [
      "Ladder competes with coaches; Barbrabell works for them.",
      "Each client's program is theirs, from their own maxes, logs and injuries, not one program for thousands.",
      "Your clients' app is free.",
    ],
    pickThem: "you're a lifter who wants a good team program for $30 a month.",
    pickUs: "you're a coach who wants to give clients a better app than Ladder, with programming that's actually theirs.",
    sources: [{ label: "Ladder", url: "https://www.joinladder.com" }],
  },
];

const bySlug = new Map(rivals.map((r) => [r.slug, r]));

export function compareRoute(path: string, served: Site): Page | undefined {
  const site = { ...served, origin: served.home ?? served.origin };
  if (path === "/compare") return html(hub(site));
  const slug = /^\/compare\/([a-z-]+)$/.exec(path)?.[1];
  const rival = slug && bySlug.get(slug);
  if (rival) return html(rivalPage(rival, site));
  if (path === "/robots.txt") return text(`User-agent: *\nAllow: /\nDisallow: /app/\n\nSitemap: ${site.origin}/sitemap.xml\n`);
  if (path === "/sitemap.xml") return { status: 200, type: "application/xml; charset=utf-8", body: sitemap(site) };
  if (path === "/llms.txt") return text(llms(site));
  return undefined;
}

const text = (body: string): Page => ({ status: 200, type: "text/plain; charset=utf-8", body });

/** The public pages worth indexing; shared items and the dashboard aren't. */
export const indexed = ["/", "/claude", "/compare", ...rivals.map((r) => `/compare/${r.slug}`), "/docs", "/privacy", "/terms", "/support"];

function sitemap(site: Site) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${indexed.map((p) => `  <url><loc>${site.origin}${p}</loc><lastmod>${ISO}</lastmod></url>`).join("\n")}
</urlset>
`;
}

/** llmstxt.org: what an assistant should know about the product, in plain Markdown. */
function llms(site: Site) {
  const app = site.appName;
  return `# ${app}

> ${app} lets strength coaches program and track their clients from Claude or ChatGPT. Clients train and log in a free iPhone app with no AI account. Coaches pay ${US.price}

- Coaches add ${app} to Claude or ChatGPT as a connector. The assistant reads each client's logged sets, notes, maxes, equipment and injuries, proposes the next week, and saves it to the client's phone when the coach says apply. Undo reverses it.
- Plans are checked in code against rules for age, equipment and injuries, whoever writes them.
- A web dashboard shows who trained, who's slipping and who reported pain.
- Coaches bring existing programs over by pasting a spreadsheet, CSV, PDF or screenshot into the assistant.
- Not included: client payments, nutrition plans, video messaging, branded apps, and an Android client app.
- Lifters training without a coach can use it free too.

## Pages

- [For coaches](${site.origin}/): what it is, price, how to start
- [Connect Claude](${site.origin}/claude): the connector address and steps
- [Connector docs](${site.origin}/docs): every tool the connector offers
- [Compare](${site.origin}/compare): ${app} against ${rivals.map((r) => r.name).join(", ")}
${rivals.map((r) => `- [${app} vs ${r.name}](${site.origin}/compare/${r.slug})`).join("\n")}
- [Privacy](${site.origin}/privacy)
`;
}

/** JSON-LD in the body: Google reads it there, and "<" can't close the script. */
const ld = (data: object) => `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, "\\u003c")}</script>`;

function hub(site: Site) {
  const app = esc(site.appName);
  return layout(site, {
    title: `${site.appName} vs the alternatives for strength coaches`,
    description: `How ${site.appName} compares with ${rivals.slice(0, 5).map((r) => r.name).join(", ")} and more: price, AI programming and the client app.`,
    path: "/compare",
    body: `${style}<article class="doc">
      <p class="eyebrow">Compare</p>
      <h1>${app} vs the alternatives</h1>
      <p class="lede">${app} is for strength coaches who already use Claude or ChatGPT. The assistant writes and changes each client's week from what they logged, and the client follows it in a free app. ${esc(US.price)}</p>
      <h2>Why ${app}</h2>
      <ul>
        <li><b>Programs written from real logs.</b> The assistant reads every set, note and sore knee, and proposes the next week.</li>
        <li><b>Nothing to finish elsewhere.</b> Say apply and it's on the client's phone, with undo.</li>
        <li><b>One price.</b> $19.99 a month for any number of clients. Most tools charge more as your roster grows.</li>
        <li><b>Simple for clients.</b> Today's session, sets to check off, progress. No AI account.</li>
      </ul>
      <h2>What ${app} doesn't do</h2>
      <p>No client payments, nutrition plans, video messaging or branded apps, and the client app is iPhone only for now. If you need those, one of the tools below may suit you better, and each page says which.</p>
      <h2>Every comparison</h2>
      <ul class="rivals">${rivals.map((r) => `<li><a href="/compare/${r.slug}"><b>${app} vs ${esc(r.name)}</b><span>${esc(r.kind)} · ${esc(r.what)}</span></a></li>`).join("")}</ul>
      <p class="fine">Prices checked ${CHECKED} on each vendor's pricing page unless the page says otherwise. Spot something out of date? <a href="/support">Tell us</a>.</p>
      <div class="actions"><a class="button primary" href="${START}">Start coaching</a></div>
    </article>
    ${ld({ "@context": "https://schema.org", "@type": "ItemList", name: `${site.appName} comparisons`,
      itemListElement: rivals.map((r, i) => ({ "@type": "ListItem", position: i + 1, name: `${site.appName} vs ${r.name}`, url: `${site.origin}/compare/${r.slug}` })) })}`,
  });
}

function rivalPage(r: Rival, site: Site) {
  const app = esc(site.appName);
  const name = esc(r.name);
  const faq = [
    {
      q: `Is ${site.appName} cheaper than ${r.name}?`,
      a: r.at ? `At 20 clients, ${site.appName} is $19.99 a month and ${r.name} is ${r.at[1]}. ${site.appName} has no client cap.` : `${site.appName} is $19.99 a month for any number of clients. ${r.name}: ${r.price}`,
    },
    {
      q: `Can I move my clients from ${r.name} to ${site.appName}?`,
      a: `Yes. Paste or upload a client's program (a spreadsheet, CSV, PDF or screenshot) into Claude or ChatGPT with ${site.appName} connected, and it lays the weeks out on the client's phone. Then send each client an invite link.`,
    },
    {
      q: `Do my clients need Claude or ChatGPT?`,
      a: `No. Clients use the free ${site.appName} iPhone app. Only the coach connects an assistant.`,
    },
  ];
  const rows: [string, string, string][] = [
    ["Price", US.price, r.price],
    ...(r.at ? (["10 clients", "20 clients", "40 clients"].map((label, i) => [label, "$19.99", r.at![i]]) as [string, string, string][]) : []),
    ["AI programming", US.ai, r.ai],
    ["Client app", US.clients, r.clients],
  ];
  return layout(site, {
    title: `${site.appName} vs ${r.name}: which is better for strength coaches?`,
    description: `${site.appName} vs ${r.name}, compared fairly: price, AI programming, the client app, and who should pick which.`,
    path: `/compare/${r.slug}`,
    body: `${style}<article class="doc">
      <p class="eyebrow"><a href="/compare">Compare</a> · ${esc(r.kind)}</p>
      <h1>${app} vs ${name}</h1>
      <p class="fine">Updated ${CHECKED}</p>
      <p class="lede"><b>Short answer:</b> pick ${name} if ${esc(r.pickThem)} Pick ${app} if ${esc(r.pickUs)}</p>
      <h2>What each one is</h2>
      <p><b>${name}:</b> ${esc(r.what)}</p>
      <p><b>${app}:</b> a connector that lets you coach clients from Claude or ChatGPT, and a free iPhone app your clients train from.</p>
      <h2>At a glance</h2>
      <table class="vs"><thead><tr><th></th><th>${app}</th><th>${name}</th></tr></thead>
        <tbody>${rows.map(([k, a, b]) => `<tr><th>${esc(k)}</th><td>${esc(a)}</td><td>${esc(b)}</td></tr>`).join("")}</tbody></table>
      <h2>Where ${name} is better</h2>
      <ul>${r.better.map((s) => `<li>${esc(s)}</li>`).join("")}</ul>
      <h2>Where ${app} is better</h2>
      <ul>${r.worse.map((s) => `<li>${esc(s)}</li>`).join("")}</ul>
      <h2>Questions</h2>
      <dl>${faq.map((f) => `<dt>${esc(f.q)}</dt><dd>${esc(f.a)}</dd>`).join("")}</dl>
      ${r.sources.length ? `<p class="fine">Sources: ${r.sources.map((s) => `<a href="${esc(s.url)}" rel="nofollow">${esc(s.label)}</a>`).join(" · ")}, checked ${CHECKED}. Prices change; check theirs before you decide.</p>` : ""}
      <div class="actions"><a class="button primary" href="${START}">Start coaching</a><a class="button" href="/compare">Other comparisons</a></div>
    </article>
    ${ld({ "@context": "https://schema.org", "@type": "Article", headline: `${site.appName} vs ${r.name}`, dateModified: ISO,
      author: { "@type": "Organization", name: site.appName }, mainEntityOfPage: `${site.origin}/compare/${r.slug}` })}
    ${ld({ "@context": "https://schema.org", "@type": "FAQPage",
      mainEntity: faq.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.a } })) })}`,
  });
}

const style = `<style>
.doc{padding:16px 0 40px}
.doc h1{margin-top:6px}
.doc h2{margin:28px 0 8px;font-size:19px}
.doc p,.doc li,.doc dd{color:var(--muted);text-wrap:pretty}
.doc p+p{margin-top:10px}
.doc .lede{margin-top:14px}
.doc ul{margin-top:8px;padding-left:20px;display:grid;gap:6px}
.doc b,.doc dt{color:var(--text);font-weight:650}
.doc dl{display:grid;gap:4px}.doc dt{margin-top:12px}
.doc a{color:var(--text)}
.doc .eyebrow a{color:inherit;text-decoration:none}
.vs{width:100%;border-collapse:collapse;font-size:15px;margin-top:8px}
.vs th,.vs td{text-align:left;vertical-align:top;padding:10px 8px;border-bottom:1px solid var(--line)}
.vs td{color:var(--muted);width:40%}
.vs thead th{font-size:13px;letter-spacing:.04em;text-transform:uppercase;color:var(--muted)}
.vs tbody th{font-weight:650;width:20%}
.rivals{list-style:none;padding:0!important;gap:8px!important}
.rivals a{display:grid;gap:2px;text-decoration:none;background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:14px 16px}
.rivals span{color:var(--muted);font-size:14px}
</style>`;
