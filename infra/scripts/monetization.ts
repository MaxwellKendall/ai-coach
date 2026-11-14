// FIT-454: the monetization switch (shared/monetization.ts). With no strategy it prints the current one.
//   AWS_PROFILE=aicoach-dev npm run monetization -- prod
//   AWS_PROFILE=aicoach-dev npm run monetization -- prod hard
//   AWS_PROFILE=aicoach-dev npm run monetization -- prod freemium
// The app reads it from /monetization.json, which CloudFront keeps up to 5 minutes; the connector reads it on every call.
import { isStrategy, STRATEGIES } from "../../shared/monetization.ts";
import { stackOutputs } from "./stack.ts";

const [stage, strategy] = process.argv.slice(2);
if (!stage || (strategy !== undefined && !isStrategy(strategy))) {
  throw new Error(`Usage: npm run monetization -- STAGE [${STRATEGIES.join("|")}]`);
}
const out = await stackOutputs(stage);
process.env.TABLE = `AICoach-${stage}`;
process.env.AWS_REGION = out.Region;
const { readMonetization, setMonetization } = await import("../lambda/monetization.ts");
const now = strategy ? await setMonetization(strategy) : await readMonetization();
console.log(`${stage}: ${now.strategy}${now.since ? ` (hard for accounts made since ${now.since})` : ""}`);
