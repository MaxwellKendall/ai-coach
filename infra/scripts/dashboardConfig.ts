// FIT-127: web/public/config.json for the dashboard's dev server (npm --prefix ../web run dev), from a deployed
// stack. The deployed dashboard gets the same file from CDK. These IDs aren't secrets; the file is gitignored anyway.
import { writeFileSync } from "node:fs";
import { stackOutputs } from "./stack.ts";

const stage = process.argv[2] ?? "dev";
const out = await stackOutputs(stage);
const config = {
  region: out.Region,
  clientId: out.WebClientId,
  cognitoDomain: out.CognitoDomain,
  graphqlUrl: out.GraphqlUrl,
  providers: out.IdentityProviders === "none" ? [] : out.IdentityProviders.split(","),
};
const path = new URL("../../web/public/config.json", import.meta.url);
writeFileSync(path, JSON.stringify(config, null, 2) + "\n");
console.log(`Wrote ${path.pathname} for AICoach-${stage}`);
