// Writes Resources/amplify_outputs.json for the iOS app (Amplify Swift's config format).
// These IDs aren't secrets, so the file is committed.
import { writeFileSync } from "node:fs";
import { stackOutputs } from "./stack.ts";

const stage = process.argv[2] ?? "dev";
const out = await stackOutputs(stage);
const providers = out.IdentityProviders === "none" ? [] : out.IdentityProviders.split(",").map((p) => p.toUpperCase());

const config = {
  version: "1",
  auth: {
    aws_region: out.Region,
    user_pool_id: out.UserPoolId,
    user_pool_client_id: out.AppClientId,
    oauth: {
      identity_providers: providers,
      domain: out.CognitoDomain,
      scopes: ["openid", "email", "profile"],
      redirect_sign_in_uri: ["aicoach://auth/callback"],
      redirect_sign_out_uri: ["aicoach://auth/signout"],
      response_type: "code",
    },
    standard_required_attributes: [],
    username_attributes: [],
    user_verification_types: [],
  },
  data: {
    aws_region: out.Region,
    url: out.GraphqlUrl,
    default_authorization_type: "AMAZON_COGNITO_USER_POOLS",
    authorization_types: [],
  },
};

const path = new URL("../../Resources/amplify_outputs.json", import.meta.url);
writeFileSync(path, JSON.stringify(config, null, 2) + "\n");
console.log(`Wrote ${path.pathname} for AICoach-${stage}`);
