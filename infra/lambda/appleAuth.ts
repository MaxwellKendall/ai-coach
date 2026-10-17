import type {
  CreateAuthChallengeTriggerEvent,
  DefineAuthChallengeTriggerEvent,
  PreSignUpTriggerEvent,
  VerifyAuthChallengeResponseTriggerEvent,
} from "aws-lambda";
import { verifyAppleToken } from "./appleToken.ts";

/**
 * FIT-138: Cognito custom auth for native Sign in with Apple. One challenge: the app answers with Apple's identity
 * token and its nonce, and Verify accepts it when the token is good and belongs to this user.
 */

/** The Apple user a Cognito username stands for: native `apple_<sub>` users and older federated ones. */
export function appleSubject(username: string): string | undefined {
  for (const prefix of ["apple_", "SignInWithApple_"]) {
    if (username.startsWith(prefix)) return username.slice(prefix.length);
  }
  return undefined;
}

export async function define(event: DefineAuthChallengeTriggerEvent) {
  const session = event.request.session;
  const last = session.at(-1);
  // Cognito still runs the flow for an unknown user (it doesn't reveal who exists); appleStart should have made them.
  if (event.request.userNotFound) console.log("no such user", event.userName);
  if (session.length === 0) {
    event.response.challengeName = "CUSTOM_CHALLENGE";
    event.response.issueTokens = false;
    event.response.failAuthentication = false;
  } else if (session.length === 1 && last?.challengeName === "CUSTOM_CHALLENGE" && last.challengeResult) {
    event.response.issueTokens = true;
    event.response.failAuthentication = false;
  } else {
    event.response.issueTokens = false;
    event.response.failAuthentication = true;
  }
  return event;
}

export async function create(event: CreateAuthChallengeTriggerEvent) {
  event.response.publicChallengeParameters = { kind: "apple" };
  event.response.privateChallengeParameters = {};
  event.response.challengeMetadata = "APPLE";
  return event;
}

/** Lambda calls a handler with (event, context), so the time can't be an optional second parameter here. */
export const verifyChallenge = (event: VerifyAuthChallengeResponseTriggerEvent) => checkAnswer(event, new Date());

export async function checkAnswer(event: VerifyAuthChallengeResponseTriggerEvent, now: Date) {
  event.response.answerCorrect = false;
  const subject = appleSubject(event.userName);
  try {
    const { identityToken, nonce } = JSON.parse(event.request.challengeAnswer) as { identityToken: string; nonce: string };
    const result = subject ? await verifyAppleToken(identityToken, nonce, now) : { ok: false as const, why: "not an Apple user" };
    if (result.ok && result.claims.sub === subject) event.response.answerCorrect = true;
    else console.log("refused", result.ok ? "another Apple user" : result.why);
  } catch (e) {
    // The answer's shape, never its content (it holds Apple's token).
    const answer = String(event.request.challengeAnswer ?? "");
    console.log("refused", "unreadable answer", (e as Error).message, { length: answer.length, starts: answer.slice(0, 1) });
  }
  return event;
}

/** Users come from Apple or Google, or from appleStart (AdminCreateUser); nobody signs up with a password. */
export async function preSignUp(event: PreSignUpTriggerEvent) {
  if (event.triggerSource === "PreSignUp_SignUp") throw new Error("Sign in with Apple or Google.");
  return event;
}
