import { createSign } from "node:crypto";
import { connect } from "node:http2";

export type ApnsKey = { teamId: string; keyId: string; privateKey: string; bundleId: string };

// APNs accepts a provider token for up to an hour; refresh well before that.
const TOKEN_TTL_MS = 50 * 60 * 1000;
let cached: { jwt: string; at: number } | undefined;

const b64url = (s: string | Buffer) => Buffer.from(s).toString("base64url");

export function providerToken(key: ApnsKey, now = Date.now()) {
  if (cached && now - cached.at < TOKEN_TTL_MS) return cached.jwt;
  const header = b64url(JSON.stringify({ alg: "ES256", kid: key.keyId }));
  const claims = b64url(JSON.stringify({ iss: key.teamId, iat: Math.floor(now / 1000) }));
  const signature = createSign("SHA256")
    .update(`${header}.${claims}`)
    .sign({ key: key.privateKey, dsaEncoding: "ieee-p1363" });
  cached = { jwt: `${header}.${claims}.${b64url(signature)}`, at: now };
  return cached.jwt;
}

/** Sends one alert per device token over a single HTTP/2 connection. Returns each token's HTTP status. */
export async function sendAlerts(host: string, key: ApnsKey, tokens: string[], alert: { title: string; body: string }, data: Record<string, string>) {
  if (tokens.length === 0) return new Map<string, number>();
  const session = connect(`https://${host}`);
  const jwt = providerToken(key);
  const payload = JSON.stringify({ aps: { alert, sound: "default" }, ...data });
  try {
    const results = await Promise.all(
      tokens.map(
        (token) =>
          new Promise<[string, number]>((resolve, reject) => {
            const req = session.request({
              ":method": "POST",
              ":path": `/3/device/${token}`,
              authorization: `bearer ${jwt}`,
              "apns-topic": key.bundleId,
              "apns-push-type": "alert",
            });
            req.on("response", (headers) => resolve([token, Number(headers[":status"])]));
            req.on("error", reject);
            req.resume();
            req.end(payload);
          }),
      ),
    );
    return new Map(results);
  } finally {
    session.close();
  }
}
