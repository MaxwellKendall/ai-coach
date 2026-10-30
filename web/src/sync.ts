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
export const pushDay = (config: Config, day: string, rows: PlanRow[], uid?: string) => pushUnit(config, `plan#${day}`, rows, uid);

/** FIT-200: a day's logged rows, corrected; as pushDay. */
export const pushLog = (config: Config, day: string, rows: LogRow[], uid?: string) => pushUnit(config, `log#${day}`, rows, uid);

/** The unit as it's pushed, also kept in the page's own copy of the units. */
export const unitOf = (key: string, rows: unknown[]): Unit =>
  ({ key, updatedAt: new Date().toISOString(), deleted: rows.length === 0, body: rows.length ? JSON.stringify(rows) : null });

async function pushUnit(config: Config, key: string, rows: unknown[], uid?: string): Promise<boolean> {
  const unit = unitOf(key, rows);
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

// FIT-200: the author of a reply corrects or deletes it.
export const editComment = (config: Config, c: Comment, text: string, uid?: string) =>
  gql<{ editComment: Comment }>(config, `mutation($u: ID, $d: String!, $a: AWSDateTime!, $t: String!) { editComment(uid: $u, day: $d, at: $a, text: $t) { day at by byName text } }`,
    { u: uid ?? null, d: c.day, a: c.at, t: text }).then((d) => d.editComment);

export const deleteComment = (config: Config, c: Comment, uid?: string) =>
  gql(config, `mutation($u: ID, $d: String!, $a: AWSDateTime!) { deleteComment(uid: $u, day: $d, at: $a) }`, { u: uid ?? null, d: c.day, a: c.at });

// FIT-131: programs a coach sends.
export type Offer = {
  id: string; coachUid: string; coachName: string | null; note: string; start: string; weeks: number;
  days: string; addPerWeek: number; status: "sent" | "started" | "declined"; createdAt: string; answeredAt: string | null;
};
export type TemplateDay = { weekday: number; slot: string; rows: { template: string; targets: Measurement[]; note: string; group?: number; main: boolean }[] };

export const sendProgram = (config: Config, uid: string, start: string, weeks: number, note: string, days: TemplateDay[], addPerWeek: number) =>
  gql<{ sendProgram: Offer }>(config,
    `mutation($u: ID!, $s: String!, $w: Int!, $n: String, $d: AWSJSON!, $a: Float) { sendProgram(uid: $u, start: $s, weeks: $w, note: $n, days: $d, addPerWeek: $a) { id status } }`,
    { u: uid, s: start, w: weeks, n: note, d: JSON.stringify(days), a: addPerWeek }).then((d) => d.sendProgram);

export const programOffers = (config: Config, uid: string) =>
  gql<{ programOffers: Offer[] }>(config,
    `query($u: ID) { programOffers(uid: $u) { id coachUid coachName note start weeks days addPerWeek status createdAt answeredAt } }`, { u: uid })
    .then((d) => d.programOffers);

// FIT-290: a pasted program read into a proposal for a client, then saved into their plan.
export type ImportedProgram = { id: string; preview: string; days: number; added: string[] };
const zone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;

/** FIT-291: pasted cells or a CSV's text, a PDF as base64, or a shared Google Sheets link. */
export type ImportSource = { text?: string; pdf?: string; sheet?: string };

export const importProgram = (config: Config, uid: string, source: ImportSource, start: string) =>
  gql<{ importProgram: ImportedProgram }>(config, `mutation($u: ID!, $x: String, $p: String, $h: String, $s: String!, $z: String) { importProgram(uid: $u, text: $x, pdf: $p, sheet: $h, start: $s, tz: $z) { id preview days added } }`,
    { u: uid, x: source.text, p: source.pdf, h: source.sheet, s: start, z: zone() }).then((d) => d.importProgram);

export const applyImport = (config: Config, uid: string, id: string) =>
  gql<{ applyImport: number }>(config, `mutation($u: ID!, $i: ID!, $z: String) { applyImport(uid: $u, id: $i, tz: $z) }`, { u: uid, i: id, z: zone() }).then((d) => d.applyImport);
