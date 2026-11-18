// TKL-773: send the version and its subscriptions to App Review in one submission.
// Handles what App Store Connect refused on 2026-11-17 (TKL-431): a rejected submission left in
// UNRESOLVED_ISSUES, first-time subscription groups that need a group version, in-flight
// subscription versions (409), and a version set to release itself on approval.
import { reviewSubmissionPlan } from "./subscriptions.mjs";

const BUSY_STATES = new Set(["WAITING_FOR_REVIEW", "IN_REVIEW"]);
// A submission in these states takes no new items: cancelled (UNRESOLVED_ISSUES) or already closing.
const CLOSED_STATES = new Set(["COMPLETE", "COMPLETED", "CANCELING", "COMPLETING"]);

/**
 * found: { app, versions, submissions } from readStore; subs: { submit: [{ productId, id, groupId?, versionId? }] }.
 * versionString: the MARKETING_VERSION to submit.
 */
export async function sendToReview(client, found, subs, { versionString, log = console.log } = {}) {
  const busy = found.submissions.find((item) => BUSY_STATES.has(item.state));
  if (busy) throw new Error(`A review submission is already ${busy.state}.`);
  const version = found.versions.find((item) => item.attributes.versionString === versionString);
  if (!version) throw new Error(`No version record ${versionString} to submit.`);

  // Approval must not publish the app: releasing to users is Maxwell's.
  if (version.attributes.releaseType !== "MANUAL") {
    await client.patch(`/v1/appStoreVersions/${version.id}`, {
      data: { type: "appStoreVersions", id: version.id, attributes: { releaseType: "MANUAL" } },
    });
    log("Release set to Manual: approval does not publish the app.");
  }

  for (const item of found.submissions.filter((row) => row.state === "UNRESOLVED_ISSUES")) {
    await client.patch(`/v1/reviewSubmissions/${item.id}`, {
      data: { type: "reviewSubmissions", id: item.id, attributes: { canceled: true } },
    });
    log(`Cancelled review submission ${item.id} (UNRESOLVED_ISSUES); it takes no new items.`);
  }
  const open = found.submissions.find((item) => !CLOSED_STATES.has(item.state) && item.state !== "UNRESOLVED_ISSUES");
  let submissionId = open?.id;
  if (!submissionId) {
    const made = await client.post("/v1/reviewSubmissions", {
      data: {
        type: "reviewSubmissions",
        attributes: { platform: "IOS" },
        relationships: { app: { data: { type: "apps", id: found.app.id } } },
      },
    });
    submissionId = made.data.id;
  }

  const listed = await client.get(`/v1/reviewSubmissions/${submissionId}/items?include=appStoreVersion,subscriptionVersion,subscriptionGroupVersion`);
  const rows = (listed.data || []).filter((item) => item.type === "reviewSubmissionItems");
  const existingItems = rows.map((item) => ({
    appStoreVersionId: item.relationships?.appStoreVersion?.data?.id || null,
    subscriptionVersionId: item.relationships?.subscriptionVersion?.data?.id || null,
  }));
  const attachedGroupVersions = new Set(rows.map((item) => item.relationships?.subscriptionGroupVersion?.data?.id).filter(Boolean));
  const attachedVersions = new Set(existingItems.map((item) => item.subscriptionVersionId).filter(Boolean));
  const addItem = (relationship, type, id) => client.post("/v1/reviewSubmissionItems", {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submissionId } },
        [relationship]: { data: { type, id } },
      },
    },
  });

  const submitting = subs?.submit || [];
  const adding = reviewSubmissionPlan({ existingItems, versionId: version.id, subscriptions: submitting });
  if (adding.addAppVersion) await addItem("appStoreVersion", "appStoreVersions", version.id);
  else log("The version is already on the review submission.");

  // One subscription group version per group being submitted; first-time groups need it
  // (SUBSCRIPTION_SUBMISSION_REQUIRES_GROUP_VERSION).
  const groups = [];
  for (const item of submitting) {
    if (!item.id) throw new Error(`${item.productId} has no subscription to submit.`);
    const groupId = item.groupId || (await client.get(`/v1/subscriptions/${item.id}?include=group`)).data?.relationships?.group?.data?.id;
    if (!groupId) throw new Error(`${item.productId} has no subscription group.`);
    if (!groups.includes(groupId)) groups.push(groupId);
  }
  for (const groupId of groups) {
    const groupVersionId = await createOrReuse(client, "/v1/subscriptionGroupVersions", {
      data: {
        type: "subscriptionGroupVersions",
        relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: groupId } } },
      },
    });
    if (attachedGroupVersions.has(groupVersionId)) continue;
    await addItem("subscriptionGroupVersion", "subscriptionGroupVersions", groupVersionId);
    attachedGroupVersions.add(groupVersionId);
  }

  for (const item of adding.subscriptions) {
    const versionId = item.versionId || await createOrReuse(client, "/v1/subscriptionVersions", {
      data: {
        type: "subscriptionVersions",
        relationships: { subscription: { data: { type: "subscriptions", id: item.id } } },
      },
    });
    if (attachedVersions.has(versionId)) continue;
    await addItem("subscriptionVersion", "subscriptionVersions", versionId);
    attachedVersions.add(versionId);
  }

  await client.patch(`/v1/reviewSubmissions/${submissionId}`, {
    data: { type: "reviewSubmissions", id: submissionId, attributes: { submitted: true } },
  });
  return { submissionId, groups };
}

/** POST; on 409 ALREADY_EXISTS, the in-flight item's id from the error detail. */
async function createOrReuse(client, path, body) {
  try {
    const made = await client.post(path, body);
    return made.data.id;
  } catch (error) {
    const id = existingId(error);
    if (!id) throw error;
    return id;
  }
}

export function existingId(error) {
  if (error?.status !== 409) return null;
  const detail = (error.body?.errors || []).map((e) => `${e.code || ""} ${e.detail || ""}`).join(" ");
  if (!/already.?exists/i.test(detail)) return null;
  const uuid = detail.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  if (uuid) return uuid[0];
  const quoted = detail.match(/(?:id\s+)?'([A-Za-z0-9-]{6,})'/);
  return quoted ? quoted[1] : null;
}
