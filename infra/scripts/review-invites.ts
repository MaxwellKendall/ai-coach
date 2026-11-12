// FIT-431: the review coach's open invite codes, for the App Store review notes. Codes are single use and last
// 14 days (lambda/coach.ts). --mint makes new ones until that many still have more than two days left.
//   AWS_PROFILE=aicoach-dev npm run review-invites -- prod COACH_UID
//   AWS_PROFILE=aicoach-dev npm run review-invites -- prod COACH_UID --mint 3
import { stackOutputs } from "./stack.ts";

const args = process.argv.slice(2);
const mintAt = args.indexOf("--mint");
const mint = mintAt >= 0 ? Number(args[mintAt + 1]) : 0;
const positional = args.filter((arg, index) => !arg.startsWith("--") && !(mintAt >= 0 && index === mintAt + 1));
const [stage, coachUid] = positional;
if (!stage || !coachUid || (mintAt >= 0 && (!Number.isInteger(mint) || mint < 1))) {
  throw new Error("Usage: npm run review-invites -- STAGE COACH_UID [--mint N]");
}

const out = await stackOutputs(stage);
process.env.TABLE = `AICoach-${stage}`;
process.env.AWS_REGION = out.Region;
process.env.SHARE_ORIGIN = out.ShareOrigin || "https://barbrabell.com";
const { createInvite, myInvites, INVITE_DAYS } = await import("../lambda/coach.ts");

const DAY = 86_400_000;
const now = new Date();
const timeLeft = (createdAt: string) => Date.parse(createdAt) + INVITE_DAYS * DAY - now.getTime();
const usable = async () => (await myInvites(coachUid, now)).filter((invite) => timeLeft(invite.createdAt) > 2 * DAY);

let open = await usable();
if (mint > 0) {
  let made = 0;
  while (open.length < mint) {
    await createInvite(coachUid, undefined, new Date());
    made++;
    open = await usable();
    if (made > mint + 2) throw new Error("Stopped making invites; they were not listing.");
  }
}
if (!open.length) console.log("(none)");
for (const invite of open) {
  const days = Math.max(0, Math.floor(timeLeft(invite.createdAt) / DAY));
  console.log(`${invite.code} (${days}d)`);
}
