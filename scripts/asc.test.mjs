import { test } from "node:test";
import assert from "node:assert/strict";
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
