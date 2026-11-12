import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";

const BASE = "https://api.appstoreconnect.apple.com";

export function loadAscEnv(env = process.env) {
  const keyId = env.ASC_KEY_ID;
  const issuerId = env.ASC_ISSUER_ID;
  const keyPath = env.ASC_KEY_PATH;
  if (!keyId || !issuerId || !keyPath) {
    throw new Error("ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set. See RELEASE.md.");
  }
  return { keyId, issuerId, keyPath };
}

function b64url(input) {
  return Buffer.from(input).toString("base64url");
}

/** ES256 JWT for the App Store Connect API. The .p8 is read here and never returned. */
export function signJwt({ keyId, issuerId, keyPath, now = Math.floor(Date.now() / 1000) }) {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    iss: issuerId,
    iat: now,
    exp: now + 15 * 60,
    aud: "appstoreconnect-v1",
  }));
  const data = `${header}.${payload}`;
  const key = readFileSync(keyPath);
  const sig = createSign("SHA256").update(data).sign({ key, dsaEncoding: "ieee-p1363" });
  return `${data}.${b64url(sig)}`;
}

export class Asc {
  constructor(auth, { dryRun = false } = {}) {
    this.auth = auth;
    this.dryRun = dryRun;
    this.token = signJwt(auth);
    this.planned = [];
  }

  async request(method, path, body, attempt = 0) {
    if (method !== "GET" && method !== "HEAD" && this.dryRun) {
      this.planned.push({ method, path });
      return { dryRun: true };
    }
    const res = await fetch(BASE + path, {
      method,
      headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = {};
    if (text) {
      try { json = JSON.parse(text); } catch { json = { raw: text.slice(0, 200) }; }
    }
    if (!res.ok) {
      if ((res.status === 429 || res.status === 503) && attempt < 5) {
        const wait = Number(res.headers.get("retry-after")) || 2 ** attempt;
        await new Promise((resolve) => setTimeout(resolve, wait * 1000));
        return this.request(method, path, body, attempt + 1);
      }
      const detail = json.errors?.map((e) => `${e.status} ${e.code || ""} ${e.title}: ${e.detail}`).join("; ")
        || text.slice(0, 400);
      const error = new Error(`${method} ${path} failed: ${detail}`);
      error.status = res.status;
      error.body = json;
      throw error;
    }
    return json;
  }

  get(path) { return this.request("GET", path); }
  post(path, body) { return this.request("POST", path, body); }
  patch(path, body) { return this.request("PATCH", path, body); }
}
