import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// FIT-127: the Cognito web client allows http://localhost:5173/ as a redirect, so the dev server stays on it.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, strictPort: true },
});
