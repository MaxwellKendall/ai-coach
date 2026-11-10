---
name: exercise-demo
description: Make the app's exercise demo clips in batches (FIT-348). Each one is a short, silent, seamless loop of one rep with perfect form, done by our faceless grey training figure, with the working muscles glowing. The job list comes from Resources/Seed/exercises.json, a run can stop and resume without paying twice, and a person approves every clip before it ships. Use when asked for "exercise demo videos", "demo clips", "how-to videos for each exercise", "more demos", or "/exercise-demo".
---

# Exercise demos

One clip per exercise: 720x720, 30fps, H.264, no audio, about 4.6s. The last frame fades into the first, so it loops without a jump. The app plays it in place of the start and end photos on the how-to sheet (`ExerciseDemos`, `LoopingVideo`).

**The look is ours.** `assets/style_full.png` and `assets/style_close.png` were made from text-only prompts, with no outside images, and `STYLE` in `scripts/manifest.py` uses the same words. Keep the two things the author asked for: the figure is **faceless**, and **the working muscles glow**. Don't add reference images or prompt text from other people's work.

## What you need
- **Higgsfield MCP:** stills (`gpt_image_2_6`) and animation (`seedance_2_5`). Add it with `claude mcp add --transport http --scope user higgsfield https://mcp.higgsfield.ai/mcp`, then sign in through `/mcp`.
- **ffmpeg** and **Python 3**.

## Steps

1. **Workdir.** Make a folder with `stills/ clips/ out/` in it, outside the repo (the scratchpad is fine).

2. **Manifest.** Build the job list from the catalog, from the repo root:
   ```
   python3 .claude/skills/exercise-demo/scripts/manifest.py build --catalog Resources/Seed/exercises.json \
       --photos Resources/Seed/exercise-photos.json --slugs goblet-squat,push-up <workdir>/demos.json
   ```
   `--slugs-from Resources/Seed/exercise-videos.json` gives the program exercises, and no slugs means the whole catalog. Each entry has its prompts, its pose reference URLs, `duration` and a `status`. Running `build` again only adds slugs. Edit a prompt in `demos.json` by hand when an exercise needs it. `manifest.py status <workdir>/demos.json` shows where the batch is.

3. **References.** Upload `assets/style_full.png` and `assets/style_close.png` once with `media_upload` (PUT the bytes with the `If-None-Match: *` header it signs, then `media_confirm`), and reuse their ids for the whole batch. For each exercise, import the first of its `pose_refs` (free-exercise-db, public domain, the start position) with `media_import_url`. It is the third reference the still prompt talks about. **Look at it:** free-exercise-db sometimes uses other equipment than our entry (its goblet squat has a kettlebell), so say "holding X instead of Y" in the still prompt. An entry with no pose refs says so in `note`. For those, drop "matching the pose of the third reference image" from the prompt and check the pose carefully.

4. **Stills.** For each `todo` entry, run `gpt_image_2_6` at 1:1 with the `still_prompt` and the three references. Save the result to `stills/<slug>.png` and look at it:
   - the right muscles glow;
   - the equipment matches the exercise;
   - the start pose is correct;
   - the whole figure is in frame with a margin.

   Regenerate until it's right. Then set `still_job` to the job id and `status` to `still`. Submit in waves of 8 or fewer, because Higgsfield returns 429 at about 9 running jobs.

5. **Clips.** For each `still` entry, run `seedance_2_5` with:
   - `mode: omni_reference`, and the still's job id as both `start_image` and `end_image`, so the rep ends where it started;
   - `aspect_ratio: 1:1`, `resolution: 720p`, `generate_audio: false`;
   - the entry's `duration` and its `motion_prompt`.

   Download the result to `clips/<slug>.mp4`, then set `clip_job` and `status: clip`.

6. **Encode.** `python3 .claude/skills/exercise-demo/scripts/encode.py clips/<slug>.mp4 out/` writes `out/<slug>.mp4` (the loop) and `out/<slug>.jpg` (a contact sheet at 2 frames a second).

7. **Review: every clip, by a person.** It's a form demo, and a clip that teaches bad form is worse than none. Show the person the contact sheet and the clip, and check:
   - **Form:** joint angles, bar or dumbbell path, grip, depth, back position. Compare against the pose refs and the cues.
   - **Rep:** one full rep that ends where it started, so the loop doesn't jump.
   - **Look:** faceless, the right muscles glow, the equipment stays the same, no camera move, no cut, no text, no extra limbs.

   If the person approves, set `status` to `approved` and `clip_file` to `out/<slug>.mp4`. Otherwise set it to `rejected` with the reason in `note`, fix the prompt, set the entry back to `todo` or `still`, and run it again.

8. **Ship.** Upload each approved `out/<slug>.mp4` to `exercises/demos/<slug>.mp4`, in the bucket behind the site's `/exercises/*` route, with content type `video/mp4`. Then write the app's list:
   ```
   python3 .claude/skills/exercise-demo/scripts/manifest.py export <workdir>/demos.json Resources/Seed/exercise-demos.json
   ```

## Cost (Higgsfield credits, Nov 2026)

| Item | Credits |
|---|---|
| a still, `gpt_image_2_6` | 0.25 |
| a 5s clip, Seedance 2.5 at 720p (7/s) | 35 |
| **per exercise, with one retry** | **about 70** |

44 exercises cost about 1,500 credits. The whole 700-exercise catalog is about 25,000, plus retries.

## Gotchas
- **Free-trial ("unlim") generations cover only some settings.** Pass `use_unlim: true` only when the person asks for it. In Nov 2026 the trial covered `gpt_image_2_6` at its default quality and resolution (1024x1024), and `seedance_2_5` only at `resolution: 480p` (a 640x640 square). Anything above that is refused, not charged. Trial clips also come with an audio track, which `encode.py` strips.
- **Keep the camera still.** Camera moves make the loop jump. The motion prompt says "Locked-off static camera". Keep that line.
- **Cable and machine moves are the weakest.** The model invents pulleys and seats. Do them last, and if one won't come out right, leave that exercise on photos.
- **Seedance outputs 24fps.** `encode.py` converts to 30.
