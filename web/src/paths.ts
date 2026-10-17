// The dashboard lives under /app on the site's own host (barbrabell.com/app); its own paths leave that off.
const BASE = import.meta.env.BASE_URL.replace(/\/$/, "");

/** The app path in the address bar. */
export const here = () => location.pathname.slice(BASE.length) || "/";

/** An app path as an address, for an href or the history. */
export const href = (to: string) => BASE + to;
