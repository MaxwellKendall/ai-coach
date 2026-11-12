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
/** Agreement, tax, or banking failures stop a real write. `exact` is the API text, with no secrets added. */
export function commerceBlock(error) {
  const errors = error?.body?.errors || [];
  const exact = errors.length
    ? errors.map((item) => [item.status, item.code, item.title, item.detail].filter(Boolean).join(" ")).join("; ")
    : (error?.message || "App Store Connect request failed");
  const code = errors[0]?.code || "";
  const blob = `${code} ${errors[0]?.title || ""} ${errors[0]?.detail || ""}`.toUpperCase();
  const blocked = code === AGREEMENT_CODE || /\b(AGREEMENT|TAX|BANKING|BANK)\b/.test(blob);
  return { blocked, exact, code };
}

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

function matchingIntros(offers, wanted) {
  return (offers || []).filter((offer) =>
    offer.duration === wanted.duration && offer.offerMode === wanted.mode && Number(offer.numberOfPeriods) === Number(wanted.periods));
}

/**
 * The yearly trial is already on the app: a broad set of matching offers is left alone.
 * A product with no offer, or a stopped run that posted only a few, still needs the rest.
 */
export function introNeedsWrite(existing, wanted, territoryCount) {
  if (!wanted) return false;
  const n = matchingIntros(existing?.introductoryOffers, wanted).length;
  if (n === 0) return true;
  if (!territoryCount || n >= territoryCount - 5) return false;
  return (existing?.priceCount || 0) < 40;
}

/** USA price differs, or a previous run equalized only a few territories. A broad price list is left alone. */
export function priceNeedsWrite(existing, product, territoryCount) {
  const target = product.tier || product.priceUSD;
  if (!sameMoney(existing?.usaPrice, target)) return true;
  const n = existing?.priceCount || 0;
  if (!territoryCount) return false;
  return n > 0 && n < 40;
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
export function planSubscriptions(desired, remote, { screenshotExists = () => false, screenshots = true } = {}) {
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
    } else if (group.displayName && existingGroup.localization?.locale === "en-US" && existingGroup.localization.name !== group.displayName) {
      actions.push({
        type: "renameGroup",
        id: existingGroup.localization.id,
        referenceName: group.referenceName,
        name: group.displayName,
      });
    } else if (group.displayName && (!existingGroup.localization || existingGroup.localization.locale !== "en-US")) {
      actions.push({ type: "createGroupLocalization", groupId: existingGroup.id, referenceName: group.referenceName, name: group.displayName });
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
        if (screenshots) noteScreenshot(product, null, screenshotExists, seenShots, actions, warnings);
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
      if (priceNeedsWrite(existing, product, remote.territoryCount || 0)) {
        actions.push({
          type: "setPrice",
          id: existing.id,
          productId: product.productId,
          priceUSD: product.priceUSD,
          tier: product.tier || existing.usaPrice || null,
          pricePointId: product.pricePointId || existing.usaPricePointId || null,
        });
      }
      if (introNeedsWrite(existing, product.introductoryOffer, remote.territoryCount || 0)) {
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
      if (screenshots && !existing.hasScreenshot) noteScreenshot(product, existing.id, screenshotExists, seenShots, actions, warnings);
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
      case "createGroupLocalization": return `Would add an en-US name ${action.name} on group ${action.referenceName}.`;
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
  let territoryCount = 0;
  try {
    territoryCount = (await pages(client, "/v1/territories?limit=200")).length;
  } catch (error) {
    if (commerceBlock(error).blocked) throw error;
  }
  return { groups, territoryCount };
}

async function readSubscription(client, sub) {
  const id = sub.id;
  const [prices, priceRows, offerRows, localizations, versions, shot] = await Promise.all([
    client.get(`/v1/subscriptions/${id}/prices?filter[territory]=USA&include=subscriptionPricePoint&limit=5`).catch(() => ({ data: [] })),
    pages(client, `/v1/subscriptions/${id}/prices?limit=200`).catch(() => []),
    pages(client, `/v1/subscriptions/${id}/introductoryOffers?include=territory&limit=200`).catch(() => []),
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
    usaPricePointId: point?.id || null,
    priceCount: priceRows.length,
    hasScreenshot: Boolean(shot.data),
    versionId: version?.id || null,
    introductoryOffers: offerRows.map((item) => ({
      ...(item.attributes || {}),
      territoryId: item.relationships?.territory?.data?.id || null,
    })),
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
        product.pricePointId = existing.usaPricePointId || null;
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

export function formatRemote(remote) {
  const lines = [`Territories: ${remote.territoryCount || "unknown"}.`];
  for (const group of remote.groups || []) {
    const shown = group.localization ? `${group.localization.locale} "${group.localization.name}"` : "no en-US name";
    lines.push(`Group ${group.referenceName} id ${group.id} ${shown}`);
    for (const sub of group.subscriptions || []) {
      const loc = (sub.localizations || []).find((item) => item.locale === "en-US");
    lines.push(`  ${sub.name} ${sub.productId} id ${sub.id} ${sub.state} USA ${sub.usaPrice ?? "none"} prices ${sub.priceCount} intro ${introSummary(sub.introductoryOffers)} ${loc ? `${loc.locale} "${loc.name}" / "${loc.description}"` : "no en-US localization"}`);
    }
  }
  if (!remote.groups?.length) lines.push("No subscription groups.");
  return lines;
}

function introSummary(offers) {
  const rows = offers || [];
  if (!rows.length) return "none";
  const first = rows[0];
  const territories = new Set(rows.map((offer) => offer.territoryId).filter(Boolean));
  const where = territories.size ? `${territories.size} territories` : `${rows.length} offers`;
  return `${first.offerMode || "offer"} ${first.duration || ""} x${first.numberOfPeriods ?? "?"} in ${where}`;
}

function isAlreadyThere(error) {
  const code = error?.body?.errors?.[0]?.code || "";
  const detail = `${code} ${error?.body?.errors?.[0]?.detail || ""}`.toLowerCase();
  return code.includes("DUPLICATE") || detail.includes("already exists") || detail.includes("duplicate");
}

function isUnsupportedTerritory(error) {
  const detail = `${error?.body?.errors?.[0]?.detail || ""} ${error?.message || ""}`.toLowerCase();
  return detail.includes("not available") || detail.includes("not supported") || detail.includes("ineligible");
}

/** Create or update what the plan names. Refuses a dry-run client. Does not delete products. */
export async function applySubscriptionPlan(client, plan, { appId, groupIds: knownGroups = new Map(), screenshots = true } = {}) {
  if (client.dryRun) throw new Error("Refusing to change subscriptions during a dry run.");
  const productIds = new Map();
  const groupIds = new Map(knownGroups);
  const actions = screenshots ? plan.actions : plan.actions.filter((action) => action.type !== "setScreenshot");
  for (const action of actions) {
    console.log(`Applying ${action.type} ${action.productId || action.referenceName || ""}`.trim());
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
    if (action.type === "createGroupLocalization" && action.groupId) {
      await client.post("/v1/subscriptionGroupLocalizations", {
        data: {
          type: "subscriptionGroupLocalizations",
          attributes: { locale: "en-US", name: action.name },
          relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: action.groupId } } },
        },
      });
      continue;
    }
    if (action.type === "createProduct") {
      const groupId = groupIds.get(action.group) || action.groupId;
      const made = await createSubscription(client, groupId, action);
      productIds.set(action.productId, made.data.id);
      console.log(`Created ${action.productId} id ${made.data.id}`);
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
      await writeLocalization(client, id, action);
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

async function createSubscription(client, groupId, action) {
  const attributes = {
    name: action.name,
    productId: action.productId,
    familySharable: false,
    subscriptionPeriod: action.period,
    groupLevel: action.period === "ONE_YEAR" ? 1 : 2,
    availableInAllTerritories: true,
  };
  try {
    return await client.post("/v1/subscriptions", subscriptionBody(groupId, attributes));
  } catch (error) {
    if (commerceBlock(error).blocked) throw error;
    const detail = error.message || "";
    if (!/availableInAllTerritories|groupLevel/.test(detail)) throw error;
    delete attributes.availableInAllTerritories;
    delete attributes.groupLevel;
    return client.post("/v1/subscriptions", subscriptionBody(groupId, attributes));
  }
}

function subscriptionBody(groupId, attributes) {
  return {
    data: {
      type: "subscriptions",
      attributes,
      relationships: { group: { data: { type: "subscriptionGroups", id: groupId } } },
    },
  };
}

async function writeLocalization(client, id, action) {
  const attributes = { name: action.localizationName, description: action.localizationDescription };
  if (action.localizationId) {
    await client.patch(`/v1/subscriptionLocalizations/${action.localizationId}`, {
      data: { type: "subscriptionLocalizations", id: action.localizationId, attributes },
    });
    return;
  }
  const body = {
    data: {
      type: "subscriptionLocalizations",
      attributes: { locale: "en-US", ...attributes },
      relationships: { subscription: { data: { type: "subscriptions", id } } },
    },
  };
  try {
    await client.post("/v1/subscriptionLocalizations", body);
  } catch (error) {
    if (commerceBlock(error).blocked) throw error;
    if (isAlreadyThere(error)) return;
    const detail = error.message || "";
    if (error.status !== 404 && !/v2|deprecated|subscription version/i.test(detail)) throw error;
    await client.post("/v2/subscriptionLocalizations", body);
  }
}

async function setUsaPrice(client, id, action) {
  let pointId = action.pricePointId;
  if (!pointId) {
    const points = await pages(client, `/v1/subscriptions/${id}/pricePoints?filter[territory]=USA&limit=200`);
    pointId = nearestPricePoint(points.map((row) => ({ id: row.id, customerPrice: row.attributes?.customerPrice })), action.priceUSD).id;
  }
  const priced = await existingPriceTerritories(client, id);
  await ensureAvailability(client, id);
  if (!priced.has("USA")) await postPrice(client, id, pointId, "USA");
  const equalized = await pages(client, `/v1/subscriptionPricePoints/${pointId}/equalizations?include=territory&limit=200`);
  let posted = 0;
  for (const row of equalized) {
    const territory = territoryFromPricePoint(row);
    if (!territory || territory === "USA" || priced.has(territory)) continue;
    await postPrice(client, id, row.id, territory);
    posted += 1;
    if (posted % 25 === 0) console.log(`Equalized ${posted} territories on ${action.productId}.`);
  }
  console.log(`Price ${action.priceUSD} set on ${action.productId}. Equalization rows ${equalized.length}. Newly posted territories: ${posted + (priced.has("USA") ? 0 : 1)}.`);
}

function territoryFromPricePoint(row) {
  const related = row.relationships?.territory?.data?.id;
  if (related) return related;
  try {
    const decoded = JSON.parse(Buffer.from(row.id, "base64url").toString("utf8"));
    return decoded.t || null;
  } catch {
    return null;
  }
}

async function ensureAvailability(client, id) {
  const territories = await pages(client, "/v1/territories?limit=200");
  try {
    await client.post("/v1/subscriptionAvailabilities", {
      data: {
        type: "subscriptionAvailabilities",
        attributes: { availableInNewTerritories: true },
        relationships: {
          subscription: { data: { type: "subscriptions", id } },
          availableTerritories: { data: territories.map((row) => ({ type: "territories", id: row.id })) },
        },
      },
    });
    console.log(`Availability set in ${territories.length} territories.`);
  } catch (error) {
    if (commerceBlock(error).blocked) throw error;
    if (isAlreadyThere(error)) return;
    throw error;
  }
}

async function existingPriceTerritories(client, id) {
  const rows = await pages(client, `/v1/subscriptions/${id}/prices?include=territory,subscriptionPricePoint&limit=200`);
  const territories = new Set();
  for (const row of rows) {
    const territory = row.relationships?.territory?.data?.id || territoryFromPricePoint({ id: row.relationships?.subscriptionPricePoint?.data?.id });
    if (territory) territories.add(territory);
  }
  return territories;
}

async function postPrice(client, id, pricePointId, territory) {
  try {
    await client.post("/v1/subscriptionPrices", priceBody(id, pricePointId, territory));
  } catch (error) {
    if (commerceBlock(error).blocked) throw error;
    if (isAlreadyThere(error)) return;
    throw error;
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
  await ensureAvailability(client, id);
  const existing = await pages(client, `/v1/subscriptions/${id}/introductoryOffers?include=territory&limit=200`);
  const have = new Set(existing.map((row) => row.relationships?.territory?.data?.id).filter(Boolean));
  const territories = await pages(client, "/v1/territories?limit=200");
  let posted = 0;
  let skipped = 0;
  for (const territory of territories) {
    if (have.has(territory.id)) continue;
    try {
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
      posted += 1;
      if (posted % 25 === 0) console.log(`Introductory offer posted for ${posted} territories on ${action.productId}.`);
    } catch (error) {
      if (commerceBlock(error).blocked) throw error;
      if (isAlreadyThere(error) || isUnsupportedTerritory(error)) {
        skipped += 1;
        continue;
      }
      throw error;
    }
  }
  console.log(`Introductory offer on ${action.productId}: posted ${posted}, already present or unsupported ${skipped + have.size}.`);
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
