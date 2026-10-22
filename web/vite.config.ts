import react from "@vitejs/plugin-react";
import { defineConfig, searchForWorkspaceRoot } from "vite";

// FIT-127: the Cognito web client allows http://localhost:5173/app/ as a redirect, so the dev server stays on it.
// The dashboard is served under /app on the site's host (barbrabell.com/app, dev.barbrabell.com/app).
export default defineConfig({
  base: "/app/",
  plugins: [react()],
  // shared/ holds what the dashboard and the lambdas both use (FIT-196's triage).
  server: { port: 5173, strictPort: true, fs: { allow: [searchForWorkspaceRoot(process.cwd()), "../shared"] } },
});
