import assert from "node:assert/strict";
import test from "node:test";
import { sendToReview } from "./review-submission.mjs";

const SV_ID = "0a1b2c3d-1111-2222-3333-444455556666";
const GV_ID = "9f8e7d6c-1111-2222-3333-444455556666";

function conflict(path, detail) {
  const error = new Error(`POST ${path} failed: 409 ENTITY_ERROR.ALREADY_EXISTS: ${detail}`);
  error.status = 409;
  error.body = { errors: [{ status: "409", code: "ENTITY_ERROR.ALREADY_EXISTS", title: "Already exists", detail }] };
  return error;
}

/** A fake App Store Connect client. Handlers are keyed "METHOD path-prefix"; every call is recorded. */
function mockClient(handlers = {}) {
  const calls = [];
  let made = 0;
  const call = async (method, path, body) => {
    calls.push({ method, path, body });
    for (const [key, handler] of Object.entries(handlers)) {
      const [m, prefix] = key.split(" ");
      if (m === method && path.startsWith(prefix)) return handler(path, body);
    }
    if (method === "POST") {
      made += 1;
      return { data: { id: `${body.data.type}-${made}`, type: body.data.type } };
    }
    if (method === "GET") return { data: [] };
    return { data: {} };
  };
  return {
    calls,
    get: (path) => call("GET", path),
    post: (path, body) => call("POST", path, body),
    patch: (path, body) => call("PATCH", path, body),
  };
}

function store({ submissions = [], releaseType = "AFTER_APPROVAL" } = {}) {
  return {
    app: { id: "app1" },
    versions: [{ id: "ver1", attributes: { versionString: "1.0", releaseType } }],
    submissions,
  };
}

const subs = {
  submit: [
    { productId: "pro.monthly", id: "sub1", groupId: "grpA", versionId: null },
    { productId: "pro.yearly", id: "sub2", groupId: "grpA", versionId: null },
    { productId: "coach.monthly", id: "sub3", groupId: "grpB", versionId: null },
  ],
};

const posts = (client, path) => client.calls.filter((c) => c.method === "POST" && c.path === path);
const itemPosts = (client, rel) => posts(client, "/v1/reviewSubmissionItems").filter((c) => c.body.data.relationships[rel]);

test("an UNRESOLVED_ISSUES submission is cancelled and a new one is created", async () => {
  const client = mockClient();
  await sendToReview(client, store({ submissions: [{ id: "old", state: "UNRESOLVED_ISSUES" }] }), { submit: [] }, { versionString: "1.0" });
  const cancel = client.calls.findIndex((c) => c.method === "PATCH" && c.path === "/v1/reviewSubmissions/old");
  const create = client.calls.findIndex((c) => c.method === "POST" && c.path === "/v1/reviewSubmissions");
  assert.ok(cancel >= 0, "cancels the old submission");
  assert.deepEqual(client.calls[cancel].body.data.attributes, { canceled: true });
  assert.ok(create > cancel, "creates the new submission after cancelling");
  const submitted = client.calls.find((c) => c.method === "PATCH" && c.body?.data?.attributes?.submitted);
  assert.equal(submitted.path, "/v1/reviewSubmissions/reviewSubmissions-1");
  assert.equal(client.calls.some((c) => c.path.startsWith("/v1/reviewSubmissions/old/items")), false, "never adds to the old one");
});

test("a READY_FOR_REVIEW submission is reused; COMPLETE and CANCELING ones are ignored", async () => {
  const client = mockClient();
  await sendToReview(client, store({ submissions: [
    { id: "done", state: "COMPLETE" },
    { id: "going", state: "CANCELING" },
    { id: "ready", state: "READY_FOR_REVIEW" },
  ] }), { submit: [] }, { versionString: "1.0" });
  assert.equal(posts(client, "/v1/reviewSubmissions").length, 0);
  assert.ok(client.calls.some((c) => c.method === "PATCH" && c.path === "/v1/reviewSubmissions/ready" && c.body.data.attributes.submitted));
  assert.equal(client.calls.some((c) => c.method === "PATCH" && c.body?.data?.attributes?.canceled), false);
});

test("a submission already waiting or in review stops the submit", async () => {
  const client = mockClient();
  await assert.rejects(
    sendToReview(client, store({ submissions: [{ id: "w", state: "WAITING_FOR_REVIEW" }] }), subs, { versionString: "1.0" }),
    /already WAITING_FOR_REVIEW/,
  );
  assert.equal(client.calls.filter((c) => c.method !== "GET").length, 0);
});

test("one subscription group version per group is added to the submission", async () => {
  const client = mockClient();
  await sendToReview(client, store(), subs, { versionString: "1.0" });
  const groupVersions = posts(client, "/v1/subscriptionGroupVersions");
  assert.deepEqual(groupVersions.map((c) => c.body.data.relationships.subscriptionGroup.data.id).sort(), ["grpA", "grpB"]);
  const items = itemPosts(client, "subscriptionGroupVersion");
  assert.equal(items.length, 2);
  for (const item of items) assert.equal(item.body.data.relationships.subscriptionGroupVersion.data.type, "subscriptionGroupVersions");
  assert.equal(itemPosts(client, "subscriptionVersion").length, 3);
  assert.equal(itemPosts(client, "appStoreVersion").length, 1);
  const submit = client.calls.findIndex((c) => c.method === "PATCH" && c.body?.data?.attributes?.submitted);
  assert.equal(submit, client.calls.length - 1, "submitted last");
});

test("a subscription without a known group reads its group first", async () => {
  const client = mockClient({ "GET /v1/subscriptions/sub9": () => ({ data: { id: "sub9", relationships: { group: { data: { id: "grpZ" } } } } }) });
  await sendToReview(client, store(), { submit: [{ productId: "x", id: "sub9", versionId: null }] }, { versionString: "1.0" });
  assert.deepEqual(posts(client, "/v1/subscriptionGroupVersions").map((c) => c.body.data.relationships.subscriptionGroup.data.id), ["grpZ"]);
});

test("an in-flight subscription version (409) is reused", async () => {
  const client = mockClient({
    "POST /v1/subscriptionVersions": (path) => { throw conflict(path, `There is already an existing subscriptionVersion with id '${SV_ID}'.`); },
  });
  await sendToReview(client, store(), { submit: [subs.submit[0]] }, { versionString: "1.0" });
  const items = itemPosts(client, "subscriptionVersion");
  assert.equal(items.length, 1);
  assert.equal(items[0].body.data.relationships.subscriptionVersion.data.id, SV_ID);
});

test("an in-flight subscription group version (409) is reused", async () => {
  const client = mockClient({
    "POST /v1/subscriptionGroupVersions": (path) => { throw conflict(path, `A subscriptionGroupVersion ${GV_ID} already exists.`); },
  });
  await sendToReview(client, store(), { submit: [subs.submit[0]] }, { versionString: "1.0" });
  const items = itemPosts(client, "subscriptionGroupVersion");
  assert.equal(items[0].body.data.relationships.subscriptionGroupVersion.data.id, GV_ID);
});

test("a 409 without an id, or another error, is not swallowed", async () => {
  const client = mockClient({
    "POST /v1/subscriptionVersions": (path) => { throw conflict(path, "Already exists."); },
  });
  await assert.rejects(sendToReview(client, store(), { submit: [subs.submit[0]] }, { versionString: "1.0" }), /409/);
  assert.equal(client.calls.some((c) => c.body?.data?.attributes?.submitted), false);
});

test("items already on a reused submission are not added again", async () => {
  const client = mockClient({
    "GET /v1/reviewSubmissions/ready/items": () => ({ data: [
      { type: "reviewSubmissionItems", relationships: { appStoreVersion: { data: { id: "ver1" } } } },
      { type: "reviewSubmissionItems", relationships: { subscriptionVersion: { data: { id: "svExisting" } } } },
      { type: "reviewSubmissionItems", relationships: { subscriptionGroupVersion: { data: { id: "gvExisting" } } } },
    ] }),
    "POST /v1/subscriptionGroupVersions": (path) => { throw conflict(path, "subscriptionGroupVersion 'gvExisting' already exists"); },
  });
  await sendToReview(client, store({ submissions: [{ id: "ready", state: "READY_FOR_REVIEW" }] }),
    { submit: [{ productId: "p", id: "sub1", groupId: "grpA", versionId: "svExisting" }] }, { versionString: "1.0" });
  assert.equal(itemPosts(client, "appStoreVersion").length, 0);
  assert.equal(itemPosts(client, "subscriptionVersion").length, 0);
  assert.equal(itemPosts(client, "subscriptionGroupVersion").length, 0);
});

test("the version's release type is set to MANUAL before submitting", async () => {
  const client = mockClient();
  await sendToReview(client, store(), { submit: [] }, { versionString: "1.0" });
  const release = client.calls.findIndex((c) => c.method === "PATCH" && c.path === "/v1/appStoreVersions/ver1");
  assert.ok(release >= 0);
  assert.deepEqual(client.calls[release].body.data.attributes, { releaseType: "MANUAL" });
  const submit = client.calls.findIndex((c) => c.method === "PATCH" && c.body?.data?.attributes?.submitted);
  assert.ok(release < submit);
});

test("a version already on MANUAL is left alone", async () => {
  const client = mockClient();
  await sendToReview(client, store({ releaseType: "MANUAL" }), { submit: [] }, { versionString: "1.0" });
  assert.equal(client.calls.some((c) => c.path === "/v1/appStoreVersions/ver1"), false);
});

test("no matching version record stops before any write", async () => {
  const client = mockClient();
  await assert.rejects(sendToReview(client, store(), subs, { versionString: "2.0" }), /No version record/);
  assert.equal(client.calls.filter((c) => c.method !== "GET").length, 0);
});
