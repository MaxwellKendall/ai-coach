import type { AppSyncResolverEvent, AppSyncIdentityCognito } from "aws-lambda";

/** A log line holds 256 KB; a report past that keeps its start, which has the crash or hang and its call stack. */
const MAX = 200_000;

/**
 * FIT-384: one MetricKit report as a log line: who, which build, and the payload (parsed when it's whole). Read with
 * Logs Insights on the diagnostics log group: `fields @timestamp, uid, app | filter diagnostic = 1`.
 */
export function line(uid: string, app: string, payload: string) {
  const whole = payload.length <= MAX;
  let report: unknown = whole ? payload : payload.slice(0, MAX);
  if (whole) {
    try {
      report = JSON.parse(payload);
    } catch {
      // Kept as text.
    }
  }
  return JSON.stringify({ diagnostic: 1, uid, app, truncated: !whole, report });
}

export const handler = async (event: AppSyncResolverEvent<{ payload: string; app: string }>) => {
  const uid = (event.identity as AppSyncIdentityCognito).sub;
  console.log(line(uid, event.arguments.app.slice(0, 64), event.arguments.payload));
  return true;
};
