import { useEffect, useState } from "react";
import type { Config, User } from "./auth";
import { coachBillingPortal, coachPlan, COACHING, hasPlan, planView, PRICES, signedInAs, startCoachPlan, type CoachPlan } from "./billing";

/** FIT-144: the coach plan: start it through Stripe Checkout, or manage it in Stripe's customer portal. */
export function BillingPage({ config, me }: { config: Config; me: User }) {
  const [plan, setPlan] = useState<CoachPlan>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const started = new URLSearchParams(location.search).has("started");
  // FIT-148: sent here from a coaching page.
  const coaching = new URLSearchParams(location.search).has("coaching");

  useEffect(() => {
    coachPlan(config).then(setPlan, (e) => setError(e.message));
  }, []);

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

  const view = plan && planView(plan);
  return (
    <>
      <header className="page">
        <h1>Billing</h1>
        {started && plan?.status === "none" && <p className="status" role="status">Thanks. Your plan shows here once Stripe confirms it.</p>}
        {coaching && plan && !hasPlan(plan) && <p className="lede">{COACHING}</p>}
        <p className="muted">{signedInAs(me)}</p>
      </header>
      {error && <p className="error" role="alert">{error}</p>}
      {!plan && !error && <p className="muted">Loading…</p>}
      {view && (
        <div className="empty billing-page">
          <p><strong>{view.title}</strong></p>
          <p className="muted">{view.detail}</p>
          {view.action === "start" && (
            <div className="actions">
              <button className="button primary" disabled={busy} onClick={open(() => startCoachPlan(config, "month"))}>Start monthly · {PRICES.month}</button>
              <button className="button" disabled={busy} onClick={open(() => startCoachPlan(config, "year"))}>Start yearly · {PRICES.year}</button>
            </div>
          )}
          {view.action === "manage" && (
            <div className="actions">
              <button className="button" disabled={busy} onClick={open(() => coachBillingPortal(config))}>Manage billing</button>
            </div>
          )}
        </div>
      )}
    </>
  );
}
