import { useEffect, useState } from "react";
import type { Config, User } from "./auth";
import { billing, hasPlan, planView, PRICES, signedInAs, type CoachPlan, type PlanKind } from "./billing";

/**
 * FIT-144: Pro, the coach plan (FIT-284): start it through Stripe Checkout, or manage it in Stripe's customer portal.
 * FIT-327: lifter Pro beside it. The coach plan includes their own training, so it isn't offered alongside an active one.
 */
export function BillingPage({ config, me }: { config: Config; me: User }) {
  const [plans, setPlans] = useState<Record<PlanKind, CoachPlan>>();
  const [error, setError] = useState<string>();
  const started = new URLSearchParams(location.search).has("started");

  useEffect(() => {
    Promise.all([billing.coach.plan(config), billing.lifter.plan(config)])
      .then(([coach, lifter]) => setPlans({ coach, lifter }), (e) => setError(e.message));
  }, []);

  const hasLifter = plans && !["none", "canceled", "incomplete_expired"].includes(plans.lifter.status);
  return (
    <>
      <header className="page">
        <h1>Billing</h1>
        {started && plans?.coach.status === "none" && <p className="status" role="status">Thanks. Your plan shows here once Stripe confirms it.</p>}
        <p className="muted">{signedInAs(me)}</p>
      </header>
      {error && <p className="error" role="alert">{error}</p>}
      {!plans && !error && <p className="muted">Loading…</p>}
      {plans && (!hasPlan(plans.coach) || hasLifter) && <PlanCard config={config} kind="lifter" plan={plans.lifter} />}
      {plans && <PlanCard config={config} kind="coach" plan={plans.coach} />}
    </>
  );
}

function PlanCard({ config, kind, plan }: { config: Config; kind: PlanKind; plan: CoachPlan }) {
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const calls = billing[kind];

  const open = (get: () => Promise<string | null>) => async () => {
    setBusy(true);
    setError(undefined);
    try {
      const url = await get();
      if (url) location.assign(url);
      else setError("Billing isn't available yet. Try again later.");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const view = planView(plan, kind);
  return (
    <div className="empty billing-page">
      <p><strong>{view.title}</strong></p>
      <p className="muted">{view.detail}</p>
      {error && <p className="error" role="alert">{error}</p>}
      {view.action === "start" && (
        <div className="actions">
          <button className="button primary" disabled={busy} onClick={open(() => calls.start(config, "month"))}>Start monthly · {PRICES[kind].month}</button>
          <button className="button" disabled={busy} onClick={open(() => calls.start(config, "year"))}>Start yearly · {PRICES[kind].year}</button>
        </div>
      )}
      {view.action === "manage" && (
        <div className="actions">
          <button className="button" disabled={busy} onClick={open(() => calls.portal(config))}>Manage billing</button>
        </div>
      )}
    </div>
  );
}
