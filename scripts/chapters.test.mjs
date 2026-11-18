// TKL-460: the review demo's client and coach chapters: one recording per part, started and stopped on the UI test's
// cues, joined with a title card before each chapter.
import { test } from "node:test";
import assert from "node:assert/strict";
import { CHAPTERS, assembleArgs, parseCue, parseCues, partFiles } from "./chapters-lib.mjs";

test("the chapters are the invited client then the coach, each with a title and its UI test", () => {
  assert.deepEqual(CHAPTERS.map((c) => c.id), ["client", "coach"]);
  for (const chapter of CHAPTERS) {
    assert.ok(chapter.title.length > 0 && chapter.detail.length > 0);
    assert.match(chapter.test, /^AICoachUITests\/ReviewChaptersUITests\/test\w+Chapter$/);
  }
});

test("a cue line names its id, begin or end, and the chapter", () => {
  assert.deepEqual(parseCue("1794966087.05 begin client\n"), { id: "1794966087.05", kind: "begin", chapter: "client" });
  assert.throws(() => parseCue("1794966087.05 start client"), /bad cue/);
  assert.throws(() => parseCue("1794966087.05 end"), /bad cue/);
});

test("cues pair each part's begin and end, in order; a chapter can have several parts", () => {
  const cues = parseCues("a begin client\nb end client\n\nc begin client\nd end client\ne begin coach\nf end coach\n");
  assert.deepEqual(cues, [
    { chapter: "client", begin: "a", end: "b" },
    { chapter: "client", begin: "c", end: "d" },
    { chapter: "coach", begin: "e", end: "f" },
  ]);
});

test("a begin without an end, an end without a begin, or overlapping parts is an error", () => {
  assert.throws(() => parseCues("a begin client\n"), /client never ended/);
  assert.throws(() => parseCues("a end coach\n"), /coach ended without beginning/);
  assert.throws(() => parseCues("a begin client\nb begin coach\n"), /coach began before client ended/);
});

test("each part has its own file, in order, and every chapter must have one", () => {
  const cues = parseCues("a begin client\nb end client\nc begin coach\nd end coach\n");
  assert.deepEqual(partFiles(cues, CHAPTERS, (i) => `part-${i}.mp4`), [
    { chapter: "client", file: "part-0.mp4" },
    { chapter: "coach", file: "part-1.mp4" },
  ]);
  assert.throws(() => partFiles(parseCues("a begin client\nb end client\n"), CHAPTERS, String), /coach was not recorded/);
});

test("the assembly puts each chapter's card before its first part, fills and holds each part, and concatenates in order", () => {
  const parts = [
    { chapter: "client", file: "p0.mp4" },
    { chapter: "client", file: "p1.mp4" },
    { chapter: "coach", file: "p2.mp4" },
  ];
  const args = assembleArgs({ parts, cards: { client: "c.png", coach: "k.png" }, out: "out.mp4", cardSeconds: 2.5 });
  const inputs = args.reduce((list, arg, index) => (arg === "-i" ? [...list, args[index + 1]] : list), []);
  assert.deepEqual(inputs, ["c.png", "k.png", "p0.mp4", "p1.mp4", "p2.mp4"]);
  const graph = args[args.indexOf("-filter_complex") + 1];
  assert.match(graph, /\[0:v\].*trim=duration=2\.5.*\[card0\]/);
  assert.match(graph, /\[1:v\].*\[card1\]/);
  // simctl writes no frames while the screen is still: constant frames, and the last one held.
  assert.match(graph, /\[2:v\]fps=30,tpad=stop_mode=clone:stop_duration=1\.5/);
  assert.match(graph, /\[card0\]\[part0\]\[part1\]\[card1\]\[part2\]concat=n=5:v=1:a=0\[out\]/);
  assert.equal(args.at(-1), "out.mp4");
  assert.ok(args.includes("-an"));
});
