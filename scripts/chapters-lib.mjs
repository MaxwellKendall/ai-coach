// TKL-460: the review demo's invited-client and coach chapters. Each runs in the Debug build's no-server demo mode
// (`-demo YES`, Maxwell's choice on TKL-460), so nothing is written to production and no hosted tokens are spent.
// ReviewChaptersUITests cues `begin` once a part's frame is clean (the app is up) and `end` before it relaunches or
// finishes, and waits for scripts/demo-video.mjs to acknowledge each cue: the recorder starts a recording of its own at
// `begin` and stops it at `end`, so no part shows the home screen or a launch. The parts are then joined, with a title
// card before each chapter. (Cutting one long recording by the clock drifted by seconds: simctl's timeline skips while
// the screen is still.)

export const CHAPTERS = [
  { id: "client", title: "Invited client", detail: "Joins their coach, follows the coach's week, logs it", test: "AICoachUITests/ReviewChaptersUITests/testClientChapter" },
  { id: "coach", title: "Coach", detail: "Signs in, invites a client, plans and reviews their week", test: "AICoachUITests/ReviewChaptersUITests/testCoachChapter" },
];

/** One cue line, `<id> begin|end <chapter>`; the id is what the recorder acknowledges. */
export function parseCue(raw) {
  const line = raw.trim();
  const [id, kind, chapter] = line.split(/\s+/);
  if (!id || !["begin", "end"].includes(kind) || !chapter) throw new Error(`bad cue: ${line}`);
  return { id, kind, chapter };
}

/** Every cue line → [{ chapter, begin, end }] (cue ids) in order, checking each begin has its end. */
export function parseCues(text) {
  const out = [];
  let open = null;
  for (const raw of text.split("\n")) {
    if (!raw.trim()) continue;
    const { id, kind, chapter } = parseCue(raw);
    if (kind === "begin") {
      if (open) throw new Error(`${chapter} began before ${open.chapter} ended`);
      open = { chapter, begin: id };
    } else {
      if (!open || open.chapter !== chapter) throw new Error(`${chapter} ended without beginning`);
      out.push({ ...open, end: id });
      open = null;
    }
  }
  if (open) throw new Error(`${open.chapter} never ended`);
  return out;
}

/** Each part's file, in order; every chapter must have at least one, so a skipped chapter fails the recording. */
export function partFiles(cues, chapters, file) {
  for (const chapter of chapters) {
    if (!cues.some((cue) => cue.chapter === chapter.id)) throw new Error(`${chapter.id} was not recorded`);
  }
  return cues.map((cue, index) => ({ chapter: cue.chapter, file: file(index) }));
}

/**
 * ffmpeg arguments: each chapter's card (a PNG, held `cardSeconds`) before its first part, then its parts, all at the
 * review video's 886 px width and 30 fps, concatenated. simctl writes no frames while the screen is still, so each part
 * is filled to a constant rate and its last frame held `holdSeconds` (the test's last pause would otherwise be lost).
 */
export function assembleArgs({ parts, cards, out, cardSeconds = 2.5, holdSeconds = 1.5, width = 886, fps = 30 }) {
  const order = [...new Set(parts.map((p) => p.chapter))];
  const inputs = [];
  const look = `scale=${width}:-2:flags=lanczos,setsar=1,format=yuv420p`;
  const filters = [];
  const sequence = [];
  let input = 0;
  const cardInput = {};
  for (const chapter of order) {
    inputs.push("-loop", "1", "-framerate", String(fps), "-t", String(cardSeconds), "-i", cards[chapter]);
    cardInput[chapter] = input++;
  }
  const seen = new Set();
  parts.forEach((part, index) => {
    inputs.push("-i", part.file);
    const at = input++;
    if (!seen.has(part.chapter)) {
      seen.add(part.chapter);
      const card = order.indexOf(part.chapter);
      filters.push(`[${cardInput[part.chapter]}:v]fps=${fps},${look},trim=duration=${cardSeconds},setpts=PTS-STARTPTS[card${card}]`);
      sequence.push(`[card${card}]`);
    }
    filters.push(`[${at}:v]fps=${fps},tpad=stop_mode=clone:stop_duration=${holdSeconds},setpts=PTS-STARTPTS,${look}[part${index}]`);
    sequence.push(`[part${index}]`);
  });
  filters.push(`${sequence.join("")}concat=n=${sequence.length}:v=1:a=0[out]`);
  return [
    "-y", ...inputs, "-filter_complex", filters.join(";"), "-map", "[out]",
    "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-crf", "26", "-preset", "medium",
    "-movflags", "+faststart", "-an", out,
  ];
}
