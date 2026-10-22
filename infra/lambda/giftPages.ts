import { actions, esc, html, layout, logo, missingPage, type Page, type Site } from "./sharePages.ts";

/**
 * FIT-122: the gift on the web. Stripe came back to /gift/thanks/{session}, which goes on to the gift's own page,
 * /g/{code}: the card to send or print, and how to redeem it. Pure, like the share pages: what's stored comes in
 * through `GiftStore`.
 *
 * FIT-214: gifts aren't sold any more (author, 2026-10-22). /gift and /gift/buy say so; a gift already bought
 * still has its page and still redeems.
 */

export interface GiftCard {
  code: string;
  for: string;
  note?: string;
  status: "unused" | "redeemed" | "refunded";
}

export interface GiftStore {
  gift(code: string): Promise<GiftCard | undefined>;
  /** The gift a Checkout Session paid for, once it's paid. */
  thanks(sessionId: string): Promise<GiftCard | undefined>;
}

/** The gift's pages, or undefined for any other path. */
export async function giftRoute(path: string, store: GiftStore, site: Site): Promise<Page | undefined> {
  if (path === "/gift" || path === "/gift/" || path === "/gift/buy") return html(offSalePage(site));
  const thanks = /^\/gift\/thanks\/([A-Za-z0-9_]{1,220})$/.exec(path)?.[1];
  if (thanks) {
    const gift = await store.thanks(thanks);
    return gift
      ? { status: 303, type: "text/plain", body: "", location: `/g/${gift.code}`, noStore: true }
      : { ...html(waitingPage(site)), noStore: true };
  }
  const code = /^\/g\/([A-Z0-9]{12})$/.exec(path)?.[1];
  if (code) {
    const gift = await store.gift(code);
    if (gift && gift.status !== "refunded") return { ...html(giftPage(gift, site)), noStore: true };
  }
  if (path.startsWith("/g/")) return { ...html(missingPage(site)), status: 404, noStore: true };
  return undefined;
}

const shown = (code: string) => code.match(/.{1,4}/g)!.join("-");

function offSalePage(site: Site) {
  return layout(site, {
    title: "Gifts are no longer sold",
    description: `${site.appName} gifts are no longer sold. A gift already bought still works.`,
    path: "/gift",
    body: `<section class="hero">
        <h1>Gifts are no longer sold</h1>
        <p class="lede">${esc(site.appName)} is now for coaches and their clients, and the app is free. Already have a gift? It still works: open its link on your iPhone to redeem it.</p>
        <div class="actions"><a class="button primary" href="/">See ${esc(site.appName)}</a></div>
      </section>`,
  });
}

function waitingPage(site: Site) {
  return layout(site, {
    title: "Your gift is on its way",
    description: site.appName,
    path: "/gift",
    body: `<section class="hero"><h1>Your gift is on its way</h1>
      <p class="lede">The payment is still being confirmed. This page will show the gift in a moment.</p>
      <script>setTimeout(() => location.reload(), 3000)</script></section>`,
  });
}

/** The card, drawn like the win cards: who it's for, the note, and the code. */
export function giftCard(gift: GiftCard, site: Site) {
  return `<div class="card paper gift">
    <p class="tag">A GIFT FOR</p>
    <p class="for">${esc(gift.for)}</p>
    ${gift.note ? `<p class="note">“${esc(gift.note)}”</p>` : ""}
    <div class="grow"></div>
    <p class="what">A year of ${esc(site.appName)} Pro</p>
    <p class="giftcode">${shown(gift.code)}</p>
    <footer><span class="mark">${logo}${esc(site.appName)}</span><span>Redeem in the app</span></footer>
  </div>`;
}

function giftPage(gift: GiftCard, site: Site) {
  const redeemed = gift.status === "redeemed";
  return layout(site, {
    title: `A gift for ${gift.for}`,
    description: `A year of ${site.appName} Pro: a program written around your goal, and a coach for every week of it.`,
    path: `/g/${gift.code}`,
    body: `${style}
      <section class="hero">
        ${giftCard(gift, site)}
        ${redeemed
          ? `<h1>This gift has been redeemed</h1><p class="lede">Enjoy the year of training.</p>`
          : `<h1>A year of coaching, for ${esc(gift.for)}</h1>
        <ol class="steps">
          <li><b>Get ${esc(site.appName)}</b><span>Free on the App Store.</span></li>
          <li><b>Set up your program and sign in</b><span>Tell it what you're training for.</span></li>
          <li><b>Redeem the gift</b><span>Open this link on your iPhone, or tap your account on Today, then Redeem a gift.</span>
            <button class="code" type="button" data-copy="${shown(gift.code)}" aria-label="Copy the code">${shown(gift.code)}<small>Copy</small></button></li>
        </ol>
        ${actions(site, [])}
        <div class="actions noprint"><button class="button" type="button" onclick="print()">Print the card</button></div>
        <p class="fine">The year starts when it's redeemed, and nothing is charged after it.</p>`}
      </section>`,
  });
}

const style = `<style>
.card.gift .for{font:700 44px/1.05 var(--round);letter-spacing:-.02em;margin-top:6px;word-break:break-word}
.card.gift .note{color:var(--c-soft);font-size:16px;margin-top:14px}
.card.gift .what{font-weight:650;font-size:15px}
.card.gift .giftcode{font:700 22px var(--round);letter-spacing:.12em;margin-top:6px}
.steps .code{font-size:20px;letter-spacing:.1em}
@media print{.top,.foot,.actions,.noprint,.fine,.steps,h1,.lede{display:none!important}body{background:#fff}.card{box-shadow:none;margin:40px auto}}
</style>`;
