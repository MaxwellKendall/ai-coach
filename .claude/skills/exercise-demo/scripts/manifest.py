#!/usr/bin/env python3
"""The job list for exercise demo clips: one entry per exercise, with its prompts and where it's got to.

  python3 manifest.py build --catalog exercises.json --photos exercise-photos.json --slugs a,b,c demos.json
  python3 manifest.py build ... --slugs-from exercise-videos.json demos.json   # the keys of a JSON object
  python3 manifest.py status demos.json
  python3 manifest.py export demos.json exercise-demos.json                    # the approved slugs, for the app

Building again adds new slugs and leaves existing entries alone (their status, job ids and any prompt you
edited by hand), so a run can stop and pick up again and never pays twice for a clip. --refresh rewrites
the prompts of entries still at "todo".

Status: todo -> still -> clip -> approved | rejected. Only "approved" is exported.
"""
import argparse, json, os, sys

PHOTOS_BASE = 'https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/'

# Our own look, in the words of the prompts that made assets/style_full.png and style_close.png (text only, no
# outside images): faceless so anyone can see themselves in it, and the working muscles glow.
STYLE = (
    "Studio 3D render for a fitness app's exercise library, in the exact look of the first two reference images: a "
    "featureless humanoid training figure made of smooth, satin, pale warm-grey material, like a high-end sculpted "
    "anatomy model, with an oval head with no face, no hair and no ears, clearly defined but natural athletic "
    "musculature, plain matte black training shorts with no logos, bare feet. A deep slate-navy seamless studio "
    "sweep that falls off to near black at the edges, with a soft floor shadow. One large soft key light from the "
    "upper left and a faint cool white edge light. The working muscles are lit from within with a warm emissive "
    "glow, deep orange at the edges and bright yellow at the centre; the rest of the body stays grey. Clean, calm, "
    "premium, medical-illustration clarity. No text, no logos, no watermark. Square 1:1 frame; the whole body and all "
    "equipment fully in frame with a margin on every side, the figure centered."
)

# How each piece of catalog equipment should look; anything unlisted is named as it is.
EQUIPMENT = {
    'barbell': 'a black Olympic barbell with black bumper plates',
    'dumbbells': 'plain black hex dumbbells',
    'kettlebells': 'a black cast-iron kettlebell',
    'bench': 'a black padded flat bench',
    'rack': 'a black squat rack',
    'cable': 'a black cable machine with a single pulley',
    'machine': 'a black weight machine',
    'bands': 'a black resistance band',
    'pull_up_bar': 'a black pull-up bar',
    'box': 'a black plyo box',
    'ez_bar': 'a black EZ curl bar',
    'medicine_ball': 'a black medicine ball',
    'exercise_ball': 'a dark grey exercise ball',
    'suspension': 'black suspension straps',
}

# The camera angle that shows each pattern's form best. A loop needs a locked-off camera.
VIEW = {
    'squat': 'side view', 'hinge': 'side view', 'lunge': 'side view', 'push': 'side view',
    'pull': 'side view', 'olympic': 'side view', 'carry': 'front 3/4 view', 'calves': 'side view',
    'shoulders': 'front view', 'arms': 'front 3/4 view', 'core': 'side view', 'legs': 'side view',
    'conditioning': 'side view',
}


def attrs(seed):
    return {a['key']: a['values'] for a in seed.get('attributes', [])}


def words(keys):
    names = [k.replace('_', ' ') for k in keys]
    return names[0] if len(names) == 1 else ', '.join(names[:-1]) + ' and ' + names[-1]


def entry(seed, photos):
    a = attrs(seed)
    muscles = words(a.get('muscles_primary') or ['working muscles'])
    gear = [EQUIPMENT.get(e, e.replace('_', ' ')) for e in a.get('equipment', [])]
    pattern = (a.get('movement_pattern') or ['push'])[0]
    view = VIEW.get(pattern, 'side view')
    # The author's cues win over free-exercise-db's steps, which sometimes name other equipment and set rep counts.
    cues = (a.get('cues') or a.get('instructions') or [])[:3]
    holding = f" with {words(gear)}" if gear else ' using only body weight'
    still = (
        f"{STYLE}\n\nSHOT: {view}, the figure doing a {seed['name'].lower()}{holding}, shown at the START "
        f"position of the movement with perfect form, matching the pose of the third reference image. "
        f"The {muscles} glow."
    )
    if cues:
        still += f" Form: {' '.join(cues[:2])}"
    motion = (
        f"The faceless grey training figure performs a slow, controlled {seed['name'].lower()} with perfect form, "
        f"1 full rep from the start position and back to exactly the same start position. "
        + (f"Form: {' '.join(cues)} " if cues else '')
        + f"The {muscles} glow orange and pulse brighter with a bright yellow core at the hardest point of the rep. "
        "Locked-off static camera, no camera movement. Dark slate studio. Keep the exact look of the start frame: "
        "same figure, same equipment, same lighting, same colors. No text, no logos, no extra people, no cuts."
    )
    refs = [PHOTOS_BASE + p for p in photos.get(seed['slug'], [])]
    return {
        'name': seed['name'],
        'status': 'todo',
        'muscles': a.get('muscles_primary', []),
        'equipment': a.get('equipment', []),
        'pose_refs': refs,
        'still_prompt': still,
        'motion_prompt': motion,
        'duration': 5,
        'still_job': None,
        'clip_job': None,
        'clip_file': None,
        'note': '' if refs else 'no free-exercise-db photos: check the pose by eye',
    }


def build(args):
    catalog = {s['slug']: s for s in json.load(open(args.catalog)) if s.get('kind', 'exercise') == 'exercise'}
    photos = json.load(open(args.photos)) if args.photos else {}
    slugs = [s for s in (args.slugs or '').split(',') if s]
    if args.slugs_from:
        slugs += list(json.load(open(args.slugs_from)))
    if not slugs:
        slugs = sorted(catalog)
    demos = json.load(open(args.out)) if os.path.exists(args.out) else {}
    unknown = [s for s in slugs if s not in catalog]
    for slug in slugs:
        if slug in unknown:
            continue
        if slug not in demos:
            demos[slug] = entry(catalog[slug], photos)
        elif args.refresh and demos[slug]['status'] == 'todo':
            fresh = entry(catalog[slug], photos)
            demos[slug].update({k: fresh[k] for k in ('still_prompt', 'motion_prompt', 'pose_refs')})
    json.dump(demos, open(args.out, 'w'), indent=2, ensure_ascii=False)
    print(f'{len(demos)} entries in {args.out}')
    if unknown:
        print('not in the catalog, skipped:', ', '.join(unknown), file=sys.stderr)


def status(args):
    demos = json.load(open(args.out))
    counts = {}
    for d in demos.values():
        counts[d['status']] = counts.get(d['status'], 0) + 1
    print(', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    for slug, d in demos.items():
        if d['status'] == 'rejected':
            print(f'  rejected {slug}: {d["note"]}')


def export(args):
    demos = json.load(open(args.out))
    approved = sorted(s for s, d in demos.items() if d['status'] == 'approved')
    json.dump(approved, open(args.app, 'w'), indent=2)
    print(f'{len(approved)} approved -> {args.app}')


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build')
    b.add_argument('--catalog', required=True)
    b.add_argument('--photos')
    b.add_argument('--slugs')
    b.add_argument('--slugs-from')
    b.add_argument('--refresh', action='store_true')
    b.add_argument('out')
    s = sub.add_parser('status')
    s.add_argument('out')
    e = sub.add_parser('export')
    e.add_argument('out')
    e.add_argument('app')
    args = p.parse_args()
    {'build': build, 'status': status, 'export': export}[args.cmd](args)


if __name__ == '__main__':
    main()
