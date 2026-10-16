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

/** Every unit the account has, newest copy of each. */
export async function pullAll(config: Config): Promise<Map<string, Unit>> {
  const units = new Map<string, Unit>();
  let since: string | null = null;
  for (;;) {
    const { syncPull: page }: { syncPull: { units: Unit[]; cursor: string | null; more: boolean } } = await gql(
      config,
      `query($s: String) { syncPull(since: $s) { units { key updatedAt deleted body } cursor more } }`,
      { s: since },
    );
    for (const unit of page.units) units.set(unit.key, unit);
    since = page.cursor;
    if (!page.more) return units;
  }
}
