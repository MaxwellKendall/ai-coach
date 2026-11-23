import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Asc } from "./asc.mjs";

// App Store Connect returns intermittent 500s on reads (TKL-431: subscription prices, twice in a row).
function client(responses) {
  const asc = Object.create(Asc.prototype);
  Object.assign(asc, { token: "t", dryRun: false, planned: [], retryUnitMs: 1 });
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push(init.method);
    const [status, body] = responses.shift();
    return { ok: status < 400, status, headers: new Map(), text: async () => JSON.stringify(body) };
  };
  return { asc, calls };
}

test("a GET that hits a 500 is retried", async () => {
  const { asc, calls } = client([[500, { errors: [{ status: "500" }] }], [200, { data: [1] }]]);
  assert.deepEqual(await asc.request("GET", "/v1/x"), { data: [1] });
  assert.equal(calls.length, 2);
});

test("a POST that hits a 500 is not retried", async () => {
  const { asc, calls } = client([[500, { errors: [{ status: "500" }] }], [200, {}]]);
  await assert.rejects(asc.request("POST", "/v1/x", {}), /failed/);
  assert.equal(calls.length, 1);
});

test("a PATCH that hits a 503 is not retried, but one that hits a 429 is", async () => {
  let { asc, calls } = client([[503, { errors: [{ status: "503" }] }], [200, {}]]);
  await assert.rejects(asc.request("PATCH", "/v1/x", {}), /failed/);
  assert.equal(calls.length, 1);
  ({ asc, calls } = client([[429, { errors: [{ status: "429" }] }], [200, { ok: 1 }]]));
  assert.deepEqual(await asc.request("PATCH", "/v1/x", {}), { ok: 1 });
  assert.equal(calls.length, 2);
});

test("requests reuse the JWT until it nears expiry and refresh after a long upload", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "asc-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const keyPath = join(directory, "test.p8");
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }));

  const start = 1_800_000_000;
  let now = start;
  t.mock.method(Date, "now", () => now * 1000);
  const tokens = [];
  t.mock.method(globalThis, "fetch", async (_url, { headers }) => {
    tokens.push(headers.Authorization);
    return { ok: true, text: async () => "{}" };
  });

  const asc = new Asc({ keyId: "test", issuerId: "test", keyPath });
  await asc.get("/v1/builds");
  now = start + 779;
  await asc.get("/v1/builds");
  assert.equal(tokens[1], tokens[0]);

  for (const [index, time] of [[2, start + 781], [3, start + 1682]]) {
    now = time;
    await asc.get("/v1/builds");
    assert.notEqual(tokens[index], tokens[index - 1]);
    const payload = JSON.parse(Buffer.from(tokens[index].split(".")[1], "base64url"));
    assert.equal(payload.iat, time);
    assert.equal(payload.exp, time + 900);
  }
});
