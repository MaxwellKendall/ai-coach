import { ACCESS_SECONDS, REFRESH_DAYS } from "./oauth.ts";
import { esc, html, layout, type Page, type Site } from "./sharePages.ts";

/**
 * FIT-158: the privacy policy, terms and support contact, which the App Store and Claude's connector directory ask
 * for. Linked from every page's footer, the OAuth consent page included.
 */

/** The author's choice for now (2026-10-22); swap for a mailbox on the domain when there is one. */
export const SUPPORT_EMAIL = "maxwell.n.kendall@gmail.com";

/** The date the policy and terms last changed in substance. */
export const UPDATED = "October 23, 2026";

export function legalRoute(path: string, site: Site): Page | undefined {
  if (path === "/privacy") return html(privacyPage(site));
  if (path === "/terms") return html(termsPage(site));
  if (path === "/support") return html(supportPage(site));
  return undefined;
}

const mail = `<a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>`;

function doc(site: Site, path: string, title: string, description: string, sections: string) {
  return layout(site, {
    title: `${title} · ${site.appName}`,
    description,
    path,
    linkHome: false,
    body: `${style}<article class="doc">
      <h1>${esc(title)}</h1>
      <p class="fine">Last updated ${UPDATED}</p>
      ${sections}
    </article>`,
  });
}

function privacyPage(site: Site) {
  const app = esc(site.appName);
  const hours = ACCESS_SECONDS / 3600;
  return doc(site, "/privacy", "Privacy policy", `What ${site.appName} keeps, who sees it, and how to delete it.`, `
    <p>${app} is a training app for coaches and the people they coach. This page says plainly what we keep, who can see it, and how to delete it.</p>

    <h2>What we keep</h2>
    <ul>
      <li><b>Your account:</b> the name Apple or Google gives us when you sign in, and an account ID. We don't receive or keep your password.</li>
      <li><b>Your training:</b> your profile (units, equipment, injuries you tell us about), goals, program and plan, the workouts and runs you log, check-ins, notes, and replies between you and your coach.</li>
      <li><b>Runs you track:</b> the run's GPS route, which is your precise location along the way, and its average heart rate, which ${app} reads from Apple Health when your Watch or AirPods measure it and you allow it. We read nothing else from Apple Health.</li>
      <li><b>Sharing:</b> anything you choose to share as a link, until you stop sharing it.</li>
      <li><b>Notifications:</b> your phone's push token, if you allow notifications.</li>
      <li><b>Billing, for coaches:</b> Stripe handles payment. We keep your Stripe customer and subscription IDs and the plan's status, never your card.</li>
    </ul>
    <p>It's stored with Amazon Web Services in the United States (DynamoDB, in the us-east-1 region), and it syncs between your phone, the web dashboard and the agents you connect. Runs you track are also saved to Apple Health on your phone, with their route, which stays under your control in the Health app.</p>
    <p>We don't sell your data, show ads, or use tracking cookies. Heart rate and other data from Apple Health is used only to show you and your coach your training: never for advertising or marketing, never sold, and never shared with anyone you haven't chosen. The pages on this site count how often each kind of page is opened, without recording who opened it.</p>

    <h2>Who can see it</h2>
    <ul>
      <li><b>You,</b> in the app, on the dashboard, and through any agent you connect.</li>
      <li><b>Your coach,</b> only after you accept their invite. A coach can see and change your program, and see your logged workouts and runs (with their routes and heart rate), check-ins and notes, so they can coach you. Either of you can end the link at any time, in the app or on the dashboard, and the coach loses access at once.</li>
      <li><b>Anyone with a link you shared,</b> until you stop sharing it.</li>
    </ul>

    <h2>AI</h2>
    <p>We don't host an AI model. When you or your coach use Claude, ChatGPT or another agent with ${app}, that agent runs on your own account with its maker, under its own privacy policy. It reads and writes your training only after you sign in to ${app} and allow it, and only through the connector you added.</p>
    <p>Earlier versions of the app could send a request through our server to Anthropic's Claude to design a program. The current app doesn't.</p>

    <h2>Agents and sign-in tokens</h2>
    <p>When you connect an agent, it gets an access token that lasts ${hours} hour${hours === 1 ? "" : "s"} and a refresh token that lasts ${REFRESH_DAYS} days. To disconnect one, remove the connector in that agent's settings; its tokens stop working when they expire, and deleting your account ends them at once.</p>

    <h2>Deleting your account</h2>
    <p>In the app, open You › Account › Delete Account. That deletes your account and everything above from our servers at once: your profile, training, shares, coach links and sign-in. If you can't use the app, email ${mail} from the address you signed in with and we'll delete it for you within 30 days.</p>
    <p>Backups of our database are kept for up to 35 days and then expire.</p>

    <h2>Your rights</h2>
    <p>Maxwell Kendall runs ${app} and is responsible for your data (its controller under the GDPR and the UK GDPR). Contact: ${mail}.</p>
    <p>Why we use it:</p>
    <ul>
      <li><b>To run the service you signed up for:</b> your account, training, sync, and the link with your coach.</li>
      <li><b>With your permission:</b> heart rate from Apple Health, your location during a run you track, and notifications. You can take it back at any time in the iPhone's Settings.</li>
      <li><b>To keep the service safe:</b> sign-in tokens, stopping abuse, and counting page views without knowing who opened them.</li>
    </ul>
    <p>Wherever you live, you can ask for a copy of your data (in a format you can take elsewhere), have it corrected or deleted, or object to or limit how we use it. Most of it you can see, change and delete yourself in the app. For anything else, email ${mail} and we'll answer within 30 days. If you're in the EU, the UK or Switzerland, you can also complain to your local data protection authority.</p>
    <p>Your data is stored and processed in the United States. Amazon Web Services stores it, Apple delivers notifications, and Stripe handles coaches' billing, each under its data processing terms, which include the EU Standard Contractual Clauses.</p>

    <h2>Children</h2>
    <p>${app} isn't meant for children under 13, and we don't knowingly keep their data.</p>

    <h2>Changes and contact</h2>
    <p>If this policy changes in a way that matters, we'll say so in the app before it takes effect. Questions: ${mail}.</p>`);
}

function termsPage(site: Site) {
  const app = esc(site.appName);
  return doc(site, "/terms", "Terms of use", `The terms for using ${site.appName}.`, `
    <p>By using ${app} (the app, this site, the dashboard or the connector), you agree to these terms.</p>

    <h2>Not medical advice</h2>
    <p>${app} helps you plan and log training. It isn't medical advice, and neither is what an agent or a coach writes with it. Check with a doctor before you start a new program, and stop if something hurts.</p>

    <h2>Your account and your data</h2>
    <p>You're responsible for what you do with your account. What you log is yours: you give us permission to store it and show it to you, to the coach you link with, to the agents you connect, and to whoever you share a link with, so the service works. The <a href="/privacy">privacy policy</a> says how.</p>

    <h2>Coaches</h2>
    <p>Coaching is free, with any number of clients. Pro, which adds the full connector for coaching from an agent, is $19.99 a month or $199 a year, billed through Stripe and renewed until you cancel. You can cancel or change it from Billing on the dashboard; it runs to the end of the period you paid for, and coaching stays free after it. A coach invites only people who've agreed to be coached, and uses their data only to coach them. Clients use ${app} free.</p>

    <h2>Agents</h2>
    <p>The agent you connect (Claude, ChatGPT or another) is a separate service under its maker's terms. It proposes changes, and you or your coach decide what's saved. We aren't responsible for what an agent says.</p>

    <h2>Fair use</h2>
    <p>Don't misuse the service: no attempts to get into other people's data, no automated abuse, nothing illegal. We may suspend an account that does.</p>

    <h2>The service</h2>
    <p>${app} is provided as it is. We work to keep it running and your data safe, but can't promise it will always be available or free of errors. To the extent the law allows, our liability is limited to what you paid us in the past 12 months.</p>

    <h2>Changes and contact</h2>
    <p>We may update these terms; if a change matters, we'll say so before it takes effect. Questions: ${mail}.</p>`);
}

function supportPage(site: Site) {
  const app = esc(site.appName);
  return doc(site, "/support", "Support", `Get help with ${site.appName}.`, `
    <p>Email ${mail}. A person reads every message.</p>

    <h2>Common questions</h2>
    <dl>
      <dt>How do I join my coach?</dt>
      <dd>Open the invite link your coach sent on your iPhone. It opens ${app} and asks you to allow it.</dd>
      <dt>How do I connect Claude?</dt>
      <dd>Follow the steps on <a href="/claude">Connect Claude</a>.</dd>
      <dt>How do I stop being coached?</dt>
      <dd>In the app, open You and tap Stop next to your coach. A coach can end it with Stop coaching on the client's page on the dashboard.</dd>
      <dt>How do I cancel Pro?</dt>
      <dd>On the dashboard, open Billing and choose Manage billing.</dd>
      <dt>How do I delete my account?</dt>
      <dd>In the app, open You › Account › Delete Account, or email us. See the <a href="/privacy">privacy policy</a>.</dd>
    </dl>`);
}

const style = `<style>
.doc{padding:16px 0 40px}
.doc h1{margin-top:12px}
.doc h2{margin:28px 0 8px;font-size:19px}
.doc p,.doc li,.doc dd{color:var(--muted);text-wrap:pretty}
.doc p+p{margin-top:10px}
.doc ul{margin-top:8px;padding-left:20px;display:grid;gap:6px}
.doc b,.doc dt{color:var(--text);font-weight:650}
.doc dl{display:grid;gap:4px}.doc dt{margin-top:12px}
.doc a{color:var(--text)}
</style>`;
