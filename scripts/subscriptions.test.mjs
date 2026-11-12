import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  assertSubscriptions,
  formatPlan,
  nearestPricePoint,
  paidAgreementStatus,
  planSubscriptions,
  REVIEW_REPLY,
  reviewSubmissionPlan,
} from "./subscriptions.mjs";

const file = JSON.parse(readFileSync(new URL("../appstore/subscriptions.json", import.meta.url), "utf8"));

test("the subscription file is the four Coach Pro and Lifter Pro products", () => {
  assertSubscriptions(file);
  const ids = file.groups.flatMap((group) => group.products.map((product) => product.productId));
  assert.deepEqual(ids, [
    "com.maxwellkendall.aicoach.pro.monthly",
    "com.maxwellkendall.aicoach.pro.yearly",
    "com.maxwellkendall.aicoach.coach.monthly",
    "com.maxwellkendall.aicoach.coach.yearly",
  ]);
  assert.equal(REVIEW_REPLY.includes("Terms of Use"), true);
});

test("nearest USA tier picks the closer price and the cheaper one on a tie", () => {
  const points = [
    { id: "a", customerPrice: "4.99" },
    { id: "b", customerPrice: "5.99" },
    { id: "c", customerPrice: "6.99" },
  ];
  assert.equal(nearestPricePoint(points, "5.99").id, "b");
  assert.equal(nearestPricePoint(points, "6.40").customerPrice, "5.99");
});

test("a missing Paid Apps agreement stops, and a successful read does not", () => {
  const blocked = paidAgreementStatus({ errorCode: "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED" });
  assert.equal(blocked.stop, true);
  assert.equal(blocked.active, false);
  const open = paidAgreementStatus({ readOk: true });
  assert.equal(open.stop, false);
  assert.match(open.message, /does not publish agreement status/);
});

test("existing product ids are updated in place and nothing is deleted", () => {
  const desired = structuredClone(file);
  desired.groups[0].products[0].tier = "5.99";
  desired.groups[0].products[1].tier = "39.99";
  const remote = {
    groups: [
      {
        id: "g1",
        referenceName: "initial",
        localization: { id: "loc", name: "Annual", locale: "en-US" },
        subscriptions: [
          {
            id: "m", productId: "com.maxwellkendall.aicoach.pro.monthly", name: "Monthly",
            state: "MISSING_METADATA", reviewNote: "", usaPrice: null, hasScreenshot: false,
            introductoryOffers: [], localizations: [],
          },
          {
            id: "y", productId: "com.maxwellkendall.aicoach.pro.yearly", name: "Annual",
            state: "READY_TO_SUBMIT", reviewNote: desired.groups[0].products[1].reviewNote, usaPrice: "39.99",
            hasScreenshot: false,
            introductoryOffers: [{ duration: "TWO_WEEKS", offerMode: "FREE_TRIAL", numberOfPeriods: 1 }],
            localizations: [{ locale: "en-US", name: "Lifter Pro", description: "AI-designed training weeks" }],
          },
          {
            id: "old", productId: "com.example.leave-me", name: "Leave me", state: "APPROVED",
            reviewNote: "", usaPrice: "1.99", hasScreenshot: true, introductoryOffers: [], localizations: [],
          },
        ],
      },
    ],
  };
  const plan = planSubscriptions(desired, remote, { screenshotExists: () => false });
  const types = plan.actions.map((action) => `${action.type}:${action.productId || action.referenceName}`);
  assert.equal(types.includes("createProduct:com.maxwellkendall.aicoach.pro.monthly"), false);
  assert.equal(types.includes("updateName:com.maxwellkendall.aicoach.pro.monthly"), true);
  assert.equal(types.includes("setPrice:com.maxwellkendall.aicoach.pro.yearly"), false);
  assert.equal(types.includes("setIntro:com.maxwellkendall.aicoach.pro.yearly"), false);
  assert.equal(types.includes("createProduct:com.maxwellkendall.aicoach.coach.monthly"), true);
  assert.equal(types.some((type) => type.startsWith("delete")), false);
  assert.equal(plan.actions.some((action) => action.productId === "com.example.leave-me"), false);
  assert.match(plan.warnings.join("\n"), /not ready to submit/);
  assert.match(plan.warnings.join("\n"), /coach-pro.png/);
  assert.match(formatPlan(plan).join("\n"), /Would create subscription group Coach Pro/);
});

test("an existing localization is patched, and an item already on the submission is not added again", () => {
  const product = structuredClone(file.groups[0].products[0]);
  product.tier = "5.99";
  const desired = { groups: [{ ...file.groups[0], products: [product] }] };
  const remote = {
    groups: [{
      id: "g1",
      referenceName: "initial",
      localization: { id: "loc", name: "Lifter Pro", locale: "en-US" },
      subscriptions: [{
        id: "m", productId: product.productId, name: product.name,
        state: "READY_TO_SUBMIT", reviewNote: product.reviewNote, usaPrice: "5.99",
        hasScreenshot: true, versionId: "sv1",
        introductoryOffers: [{ duration: "TWO_WEEKS", offerMode: "FREE_TRIAL", numberOfPeriods: 1 }],
        localizations: [{ id: "ml", locale: "en-US", name: "Old", description: "Old text" }],
      }],
    }],
  };
  const plan = planSubscriptions(desired, remote, { screenshotExists: () => true });
  const loc = plan.actions.find((action) => action.type === "setLocalization");
  assert.equal(loc.localizationId, "ml");
  const again = reviewSubmissionPlan({
    existingItems: [{ appStoreVersionId: "ver", subscriptionVersionId: "sv1" }],
    versionId: "ver",
    subscriptions: plan.submit,
  });
  assert.equal(again.addAppVersion, false);
  assert.equal(again.subscriptions.length, 0);
  const fresh = reviewSubmissionPlan({ existingItems: [], versionId: "ver", subscriptions: plan.submit });
  assert.equal(fresh.addAppVersion, true);
  assert.equal(fresh.subscriptions.length, 1);
});
