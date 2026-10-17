import { idToken, type Config } from "./auth";

// FIT-126's units, as the app writes them (Core/Cloud/SyncUnits.swift): times are seconds since 1970.

export type Measurement = { metric: string; value: number; unit: string };

export type PlanRow = {
  id: string;
  kind: string;
  at: number;
  slot?: string;
  template?: string;
  targets: Measurement[];
  note: string;
  adjustedReason?: string;
  group?: number;
  main: boolean;
  pinned: boolean;
};

export type LogRow = {
  id: string;
  kind: string;
  at: number;
  plannedRef?: string;
  template?: string;
  measurements: Measurement[];
  note: string;
};

export type Unit = { key: string; updatedAt: string; deleted: boolean; body: string | null };

export async function gql<T>(config: Config, query: string, variables: Record<string, unknown> = {}): Promise<T> {
  const token = await idToken(config);
  if (!token) throw new Error("Signed out");
  const response = await fetch(config.graphqlUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: token },
    body: JSON.stringify({ query, variables }),
  });
  const json = await response.json();
  if (json.errors?.length) throw new Error(json.errors[0].message);
  return json.data as T;
}

/** Every unit the account has, newest copy of each; `uid` is a client's (FIT-130), for their coach. */
export async function pullAll(config: Config, uid?: string): Promise<Map<string, Unit>> {
  const units = new Map<string, Unit>();
  let since: string | null = null;
  for (;;) {
    const { syncPull: page }: { syncPull: { units: Unit[]; cursor: string | null; more: boolean } } = await gql(
      config,
      `query($s: String, $u: ID) { syncPull(since: $s, uid: $u) { units { key updatedAt deleted body } cursor more } }`,
      { s: since, u: uid ?? null },
    );
    for (const unit of page.units) units.set(unit.key, unit);
    since = page.cursor;
    if (!page.more) return units;
  }
}

/** FIT-128: a day's planned rows, as this browser has them now; false when the server kept a newer copy (the phone's). */
export async function pushDay(config: Config, day: string, rows: PlanRow[], uid?: string): Promise<boolean> {
  const unit = { key: `plan#${day}`, updatedAt: new Date().toISOString(), deleted: rows.length === 0, body: rows.length ? JSON.stringify(rows) : null };
  const { syncPush }: { syncPush: { rejected: { key: string }[] } } = await gql(
    config,
    `mutation($u: [SyncUnitInput!]!, $o: ID) { syncPush(units: $u, source: "web", uid: $o) { uid source changedAt rejected { key } } }`,
    { u: [unit], o: uid ?? null },
  );
  return syncPush.rejected.length === 0;
}

// FIT-130: coaches and clients.
export type Person = { uid: string; name: string | null; since: string };

export const myClients = (config: Config) =>
  gql<{ myClients: Person[] }>(config, `query { myClients { uid name since } }`).then((d) => d.myClients);

export const createClientInvite = (config: Config) =>
  gql<{ createClientInvite: { code: string; url: string } }>(config, `mutation { createClientInvite { code url } }`).then((d) => d.createClientInvite);

export const removeClient = (config: Config, uid: string) =>
  gql(config, `mutation($u: ID!) { removeClient(uid: $u) }`, { u: uid });

// FIT-132: replies on a session.
export type Comment = { day: string; at: string; by: string; byName: string | null; text: string };

export const comments = (config: Config, uid?: string) =>
  gql<{ comments: Comment[] }>(config, `query($u: ID) { comments(uid: $u) { day at by byName text } }`, { u: uid ?? null }).then((d) => d.comments);

export const postComment = (config: Config, day: string, text: string, uid?: string) =>
  gql<{ postComment: Comment }>(config, `mutation($u: ID, $d: String!, $t: String!) { postComment(uid: $u, day: $d, text: $t) { day at by byName text } }`,
    { u: uid ?? null, d: day, t: text }).then((d) => d.postComment);
