/** Subscriptions as code for `npm run release` (FIT-386, FIT-437). Planning is pure. The apply functions write, and the release command calls them only outside a dry run. */
import { readFileSync } from "node:fs";

export const REVIEW_REPLY = "We've added a Terms of Use link to the description and the paywall, and the subscriptions are now offered in the app with the required terms.";

/** A subscription in one of these states can go out with the version, or already has. */
export const SUBMITTABLE_STATES = new Set([
  "READY_TO_SUBMIT",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "PENDING_BINARY_APPROVAL",
  "APPROVED",
]);

const PERIODS = new Set(["ONE_MONTH", "ONE_YEAR"]);
const AGREEMENT_CODE = "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED";

export function assertSubscriptions(file) {
  const groups = file?.groups;
  if (!Array.isArray(groups) || !groups.length) throw new Error("appstore/subscriptions.json needs at least one group");
  const productIds = new Set();
  const names = new Set();
  for (const group of groups) {
    if (!group.referenceName) throw new Error("a subscription group is missing referenceName");
    if (names.has(group.referenceName)) throw new Error(`duplicate group ${group.referenceName}`);
    names.add(group.referenceName);
    if (group.displayName && group.displayName.length > 30) {
      throw new Error(`group ${group.referenceName} display name is over 30 characters`);
    }
    for (const product of group.products || []) {
      if (!product.productId || productIds.has(product.productId)) {
        throw new Error(`duplicate or missing product id ${product.productId || ""}`);
      }
      productIds.add(product.productId);
      if (!PERIODS.has(product.period)) throw new Error(`${product.productId} has period ${product.period}`);
      if (!Number.isFinite(Number(product.priceUSD))) throw new Error(`${product.productId} has no USD price`);
      const loc = product.localization || {};
      if (!loc.name || loc.name.length > 30) throw new Error(`${product.productId} localization name must be 1–30 characters`);
      if (!loc.description || loc.description.length > 45) {
        throw new Error(`${product.productId} localization description must be 1–45 characters`);
      }
      if (product.reviewNote && product.reviewNote.length > 4000) {
        throw new Error(`${product.productId} review note is over 4000 characters`);
      }
    }
  }
}

/**
 * The price point closest to `target` dollars. Ties pick the cheaper tier.
 * `points` are `{ id, customerPrice }`.
 */
export function nearestPricePoint(points, target) {
  const want = Number(target);
  if (!Number.isFinite(want)) throw new Error(`price ${target} is not a number`);
  let best = null;
  for (const point of points) {
    const price = Number(point.customerPrice);
    if (!Number.isFinite(price)) continue;
    const delta = Math.abs(price - want);
    if (!best || delta < best.delta - 1e-9 || (Math.abs(delta - best.delta) < 1e-9 && price < best.price)) {
      best = { id: point.id, customerPrice: point.customerPrice, price, delta };
    }
  }
  if (!best) throw new Error(`no USA price point near ${target}`);
  return best;
}

/**
 * App Store Connect does not publish agreement status. A read that fails with the
 * missing-agreement code means the Paid Apps agreement is not active. Any other
 * successful read did not see that block.
 */
export function paidAgreementStatus({ readOk = false, errorCode = "" } = {}) {
  if (errorCode === AGREEMENT_CODE) {
    return {
      active: false,
      stop: true,
      message: "Paid Apps agreement is not active. The Account Holder signs it under Business in App Store Connect. Apple does not offer that signature through the API, so this command stops.",
    };
  }
  if (readOk) {
    return {
      active: true,
      stop: false,
      message: "Paid Apps agreement: no missing-agreement error on the subscription read. App Store Connect does not publish agreement status. Confirm Business › Agreements shows Paid Apps as Active before the first real run.",
    };
  }
  return {
    active: false,
    stop: true,
    message: "Could not read App Store Connect, so the Paid Apps agreement was not checked.",
  };
}

function sameIntro(remote, wanted) {
  if (!wanted) return true;
  return (remote.introductoryOffers || []).some((offer) =>
    offer.duration === wanted.duration && offer.offerMode === wanted.mode && offer.numberOfPeriods === wanted.periods);
}

function sameLocalization(remote, wanted) {
  return (remote.localizations || []).some((item) =>
    item.locale === wanted.locale && item.name === wanted.name && item.description === wanted.description);
}

/**
 * Diff `desired` (subscriptions.json) against `remote` groups already on the app.
 * Never emits a delete. An existing product id is updated in place, even if it
 * lives in a different group: App Store Connect will not move it.
 */
export function planSubscriptions(desired, remote, { screenshotExists = () => false } = {}) {
  const actions = [];
  const warnings = [];
  const submit = [];
  const byProduct = new Map();
  const byName = new Map();
  for (const group of remote.groups || []) {
    byName.set(group.referenceName, group);
    for (const sub of group.subscriptions || []) byProduct.set(sub.productId, { ...sub, group });
  }
  const seenShots = new Set();

  for (const group of desired.groups) {
    const existingGroup = byName.get(group.referenceName);
    if (!existingGroup) {
      actions.push({ type: "createGroup", referenceName: group.referenceName, displayName: group.displayName });
      byName.set(group.referenceName, { referenceName: group.referenceName, subscriptions: [], planned: true });
    } else if (group.displayName && existingGroup.localization && existingGroup.localization.name !== group.displayName) {
      actions.push({
        type: "renameGroup",
        id: existingGroup.localization.id,
        referenceName: group.referenceName,
        name: group.displayName,
      });
    }

    for (const product of group.products) {
      const existing = byProduct.get(product.productId);
      if (!existing) {
        actions.push({
          type: "createProduct",
          group: group.referenceName,
          productId: product.productId,
          name: product.name,
          period: product.period,
          priceUSD: product.priceUSD,
        });
        actions.push({ type: "setPrice", productId: product.productId, priceUSD: product.priceUSD, tier: product.tier || null });
        if (product.introductoryOffer) {
          actions.push({ type: "setIntro", productId: product.productId, duration: product.introductoryOffer.duration, periods: product.introductoryOffer.periods });
        }
        actions.push({
          type: "setLocalization", productId: product.productId,
          name: product.localization.name, localizationName: product.localization.name, localizationDescription: product.localization.description,
        });
        actions.push({ type: "setReviewNote", productId: product.productId, reviewNote: product.reviewNote });
        noteScreenshot(product, null, screenshotExists, seenShots, actions, warnings);
        warnings.push(`${product.name} (${product.productId}) is not on the app yet, so it is not ready to submit.`);
        submit.push({ productId: product.productId, name: product.name, state: "MISSING", versionId: null });
        continue;
      }
      if (existing.group.referenceName !== group.referenceName) {
        warnings.push(`${product.productId} stays in group "${existing.group.referenceName}". A subscription cannot be moved.`);
      }
      if (existing.name !== product.name) {
        actions.push({ type: "updateName", id: existing.id, productId: product.productId, name: product.name });
      }
      if ((existing.reviewNote || "") !== (product.reviewNote || "")) {
        actions.push({ type: "setReviewNote", id: existing.id, productId: product.productId, reviewNote: product.reviewNote });
      }
      if (product.tier && !sameMoney(existing.usaPrice, product.tier)) {
        actions.push({
          type: "setPrice",
          id: existing.id,
          productId: product.productId,
          priceUSD: product.priceUSD,
          tier: product.tier,
          pricePointId: product.pricePointId || null,
        });
      } else if (!product.tier && !sameMoney(existing.usaPrice, product.priceUSD)) {
        actions.push({ type: "setPrice", id: existing.id, productId: product.productId, priceUSD: product.priceUSD, tier: null });
      }
      if (product.introductoryOffer && !sameIntro(existing, product.introductoryOffer)) {
        actions.push({
          type: "setIntro", id: existing.id, productId: product.productId,
          duration: product.introductoryOffer.duration, periods: product.introductoryOffer.periods,
        });
      }
      if (!sameLocalization(existing, product.localization)) {
        const current = (existing.localizations || []).find((item) => item.locale === product.localization.locale);
        actions.push({
          type: "setLocalization", id: existing.id, productId: product.productId,
          localizationId: current?.id || null,
          name: product.localization.name, localizationName: product.localization.name, localizationDescription: product.localization.description,
        });
      }
      if (!existing.hasScreenshot) noteScreenshot(product, existing.id, screenshotExists, seenShots, actions, warnings);
      const ready = SUBMITTABLE_STATES.has(existing.state);
      if (!ready) warnings.push(`${product.name} (${product.productId}) is ${existing.state}, not ready to submit.`);
      submit.push({
        productId: product.productId,
        name: product.name,
        state: existing.state,
        versionId: existing.versionId || null,
        id: existing.id,
      });
    }
  }
  return { actions, warnings, submit };
}

function noteScreenshot(product, id, screenshotExists, seen, actions, warnings) {
  const path = product.screenshot;
  if (!path) return;
  if (screenshotExists(path)) {
    actions.push({ type: "setScreenshot", id, productId: product.productId, screenshot: path });
    return;
  }
  if (seen.has(path)) return;
  seen.add(path);
  warnings.push(`Paywall screenshot ${path} is missing. PaywallScreenshotUITests saves it once the paywall is in the build (FIT-437).`);
}

function sameMoney(left, right) {
  if (left == null || right == null) return false;
  return Math.abs(Number(left) - Number(right)) < 0.001;
}

export function formatPlan(plan) {
  const lines = plan.actions.map((action) => {
    switch (action.type) {
      case "createGroup": return `Would create subscription group ${action.referenceName} (${action.displayName}).`;
      case "renameGroup": return `Would rename the ${action.referenceName} group to ${action.name}.`;
      case "createProduct": return `Would create ${action.name} (${action.productId}) in ${action.group} at $${action.priceUSD}.`;
      case "updateName": return `Would rename ${action.productId} to ${action.name}.`;
      case "setReviewNote": return `Would set the subscription review note on ${action.productId}.`;
      case "setPrice":
        return action.tier
          ? `Would set ${action.productId} to the nearest USA tier $${action.tier} (asked $${action.priceUSD}) and equalize other territories.`
          : `Would set ${action.productId} to the nearest USA tier for $${action.priceUSD} and equalize other territories.`;
      case "setIntro": return `Would add a ${action.duration} free trial on ${action.productId} where one is missing.`;
      case "setLocalization": return `Would set the en-US name and description on ${action.productId}.`;
      case "setScreenshot": return `Would upload ${action.screenshot} as the paywall review screenshot for ${action.productId}.`;
      default: return action.type;
    }
  });
  if (!lines.length) lines.push("Subscriptions already match appstore/subscriptions.json.");
  return lines;
}

async function pages(client, path, limit = 20) {
  const rows = [];
  let next = path;
  let guard = 0;
  while (next && guard < limit) {
    const json = await client.get(next);
    rows.push(...(json.data || []));
    const link = json.links?.next;
    next = link ? link.replace(/^https:\/\/api\.appstoreconnect\.apple\.com/, "") : null;
    guard += 1;
  }
  return rows;
}

/** Groups, products, USA price, intro offers, localizations, and whether a review screenshot exists. Reads only. */
export async function loadRemote(client, appId) {
  const listed = await client.get(`/v1/apps/${appId}/subscriptionGroups?limit=20`);
  const groups = [];
  for (const group of listed.data || []) {
    const localizations = await client.get(`/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations?limit=10`);
    const localization = (localizations.data || []).find((item) => item.attributes?.locale === "en-US") || localizations.data?.[0];
    const subscriptions = [];
    const subs = await client.get(`/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`);
    for (const sub of subs.data || []) subscriptions.push(await readSubscription(client, sub));
    groups.push({
      id: group.id,
      referenceName: group.attributes?.referenceName || "",
      localization: localization ? {
        id: localization.id,
        name: localization.attributes?.name || "",
        locale: localization.attributes?.locale || "",
      } : null,
      subscriptions,
    });
  }
  return { groups };
}

async function readSubscription(client, sub) {
  const id = sub.id;
  const [prices, offers, localizations, versions, shot] = await Promise.all([
    client.get(`/v1/subscriptions/${id}/prices?filter[territory]=USA&include=subscriptionPricePoint&limit=5`).catch(() => ({ data: [] })),
    client.get(`/v1/subscriptions/${id}/introductoryOffers?limit=20`).catch(() => ({ data: [] })),
    client.get(`/v1/subscriptions/${id}/subscriptionLocalizations?limit=10`).catch(() => ({ data: [] })),
    client.get(`/v1/subscriptions/${id}/versions?limit=5`).catch(() => ({ data: [] })),
    client.get(`/v1/subscriptions/${id}/appStoreReviewScreenshot`).catch(() => ({ data: null })),
  ]);
  const point = (prices.included || []).find((item) => item.type === "subscriptionPricePoints");
  const version = (versions.data || [])[0];
  return {
    id,
    productId: sub.attributes?.productId || "",
    name: sub.attributes?.name || "",
    state: sub.attributes?.state || "UNKNOWN",
    reviewNote: sub.attributes?.reviewNote || "",
    usaPrice: point?.attributes?.customerPrice || null,
    hasScreenshot: Boolean(shot.data),
    versionId: version?.id || null,
    introductoryOffers: (offers.data || []).map((item) => item.attributes || {}),
    localizations: (localizations.data || []).map((item) => ({
      id: item.id,
      locale: item.attributes?.locale,
      name: item.attributes?.name,
      description: item.attributes?.description,
    })),
  };
}

/** Attach the nearest USA tier onto products whose current price is missing or different. Reads only. */
export async function withTiers(client, desired, remote) {
  const copy = structuredClone(desired);
  const byProduct = new Map();
  for (const group of remote.groups || []) {
    for (const sub of group.subscriptions || []) byProduct.set(sub.productId, sub);
  }
  for (const group of copy.groups) {
    for (const product of group.products) {
      const existing = byProduct.get(product.productId);
      if (!existing) continue;
      if (sameMoney(existing.usaPrice, product.priceUSD)) {
        product.tier = existing.usaPrice;
        continue;
      }
      const points = await pages(client, `/v1/subscriptions/${existing.id}/pricePoints?filter[territory]=USA&limit=200`);
      const nearest = nearestPricePoint(points.map((row) => ({ id: row.id, customerPrice: row.attributes?.customerPrice })), product.priceUSD);
      product.tier = nearest.customerPrice;
      product.pricePointId = nearest.id;
    }
  }
  return copy;
}

/** Create or update what the plan names. Refuses a dry-run client. Does not delete products. */
export async function applySubscriptionPlan(client, plan, { appId, groupIds: knownGroups = new Map() } = {}) {
  if (client.dryRun) throw new Error("Refusing to change subscriptions during a dry run.");
  const productIds = new Map();
  const groupIds = new Map(knownGroups);
  for (const action of plan.actions) {
    if (action.type === "createGroup") {
      const made = await client.post("/v1/subscriptionGroups", {
        data: {
          type: "subscriptionGroups",
          attributes: { referenceName: action.referenceName },
          relationships: { app: { data: { type: "apps", id: appId } } },
        },
      });
      groupIds.set(action.referenceName, made.data.id);
      if (action.displayName) {
        await client.post("/v1/subscriptionGroupLocalizations", {
          data: {
            type: "subscriptionGroupLocalizations",
            attributes: { locale: "en-US", name: action.displayName },
            relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: made.data.id } } },
          },
        });
      }
      continue;
    }
    if (action.type === "renameGroup" && action.id) {
      await client.patch(`/v1/subscriptionGroupLocalizations/${action.id}`, {
        data: { type: "subscriptionGroupLocalizations", id: action.id, attributes: { name: action.name } },
      });
      continue;
    }
    if (action.type === "createProduct") {
      const groupId = groupIds.get(action.group) || action.groupId;
      const made = await client.post("/v1/subscriptions", {
        data: {
          type: "subscriptions",
          attributes: {
            name: action.name,
            productId: action.productId,
            familySharable: false,
            subscriptionPeriod: action.period,
          },
          relationships: { group: { data: { type: "subscriptionGroups", id: groupId } } },
        },
      });
      productIds.set(action.productId, made.data.id);
      continue;
    }
    const id = action.id || productIds.get(action.productId);
    if (action.type === "updateName") {
      await client.patch(`/v1/subscriptions/${id}`, {
        data: { type: "subscriptions", id, attributes: { name: action.name } },
      });
    } else if (action.type === "setReviewNote") {
      await client.patch(`/v1/subscriptions/${id}`, {
        data: { type: "subscriptions", id, attributes: { reviewNote: action.reviewNote } },
      });
    } else if (action.type === "setPrice") {
      await setUsaPrice(client, id, action);
    } else if (action.type === "setIntro") {
      await setIntro(client, id, action);
    } else if (action.type === "setLocalization") {
      if (action.localizationId) {
        await client.patch(`/v1/subscriptionLocalizations/${action.localizationId}`, {
          data: {
            type: "subscriptionLocalizations",
            id: action.localizationId,
            attributes: { name: action.localizationName, description: action.localizationDescription },
          },
        });
      } else {
        await client.post("/v1/subscriptionLocalizations", {
          data: {
            type: "subscriptionLocalizations",
            attributes: { locale: "en-US", name: action.localizationName, description: action.localizationDescription },
            relationships: { subscription: { data: { type: "subscriptions", id } } },
          },
        });
      }
    } else if (action.type === "setScreenshot") {
      await uploadScreenshot(client, id, action.screenshot);
    }
  }
  return productIds;
}

/** Which review-submission items still need adding. An item already on the open submission is left there. */
export function reviewSubmissionPlan({ existingItems = [], versionId, subscriptions = [] } = {}) {
  const attachedVersions = new Set(existingItems.map((item) => item.subscriptionVersionId).filter(Boolean));
  return {
    addAppVersion: !existingItems.some((item) => item.appStoreVersionId === versionId),
    subscriptions: subscriptions.filter((item) => !item.versionId || !attachedVersions.has(item.versionId)),
  };
}

async function setUsaPrice(client, id, action) {
  let pointId = action.pricePointId;
  if (!pointId) {
    const points = await pages(client, `/v1/subscriptions/${id}/pricePoints?filter[territory]=USA&limit=200`);
    pointId = nearestPricePoint(points.map((row) => ({ id: row.id, customerPrice: row.attributes?.customerPrice })), action.priceUSD).id;
  }
  await client.post("/v1/subscriptionPrices", priceBody(id, pointId, "USA"));
  const equalized = await pages(client, `/v1/subscriptionPricePoints/${pointId}/equalizations?limit=200`);
  for (const row of equalized) {
    const territory = row.relationships?.territory?.data?.id;
    if (!territory || territory === "USA") continue;
    await client.post("/v1/subscriptionPrices", priceBody(id, row.id, territory));
  }
}

function priceBody(subscriptionId, pricePointId, territory) {
  return {
    data: {
      type: "subscriptionPrices",
      attributes: { startDate: null },
      relationships: {
        subscription: { data: { type: "subscriptions", id: subscriptionId } },
        subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: pricePointId } },
        territory: { data: { type: "territories", id: territory } },
      },
    },
  };
}

async function setIntro(client, id, action) {
  const territories = await pages(client, "/v1/territories?limit=200");
  for (const territory of territories) {
    await client.post("/v1/subscriptionIntroductoryOffers", {
      data: {
        type: "subscriptionIntroductoryOffers",
        attributes: { duration: action.duration, offerMode: "FREE_TRIAL", numberOfPeriods: action.periods || 1 },
        relationships: {
          subscription: { data: { type: "subscriptions", id } },
          territory: { data: { type: "territories", id: territory.id } },
        },
      },
    });
  }
}

async function uploadScreenshot(client, id, path) {
  const bytes = readFileSync(path);
  const made = await client.post("/v1/subscriptionAppStoreReviewScreenshots", {
    data: {
      type: "subscriptionAppStoreReviewScreenshots",
      attributes: { fileName: path.split("/").pop(), fileSize: bytes.length },
      relationships: { subscription: { data: { type: "subscriptions", id } } },
    },
  });
  const ops = made.data?.attributes?.uploadOperations || [];
  for (const op of ops) {
    const start = op.offset || 0;
    const slice = bytes.subarray(start, start + (op.length || bytes.length));
    const headers = new Headers();
    for (const header of op.requestHeaders || []) headers.set(header.name, header.value);
    const res = await fetch(op.url, { method: op.method || "PUT", headers, body: slice });
    if (!res.ok) throw new Error(`Paywall screenshot upload failed (${res.status}).`);
  }
  await client.patch(`/v1/subscriptionAppStoreReviewScreenshots/${made.data.id}`, {
    data: { type: "subscriptionAppStoreReviewScreenshots", id: made.data.id, attributes: { uploaded: true } },
  });
}
