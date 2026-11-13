#!/usr/bin/env python3
"""FIT-447: ship the first batch of Higgsfield form demos (scripts/demos/higgsfield-batch-1.json) on our own site.

  python3 scripts/higgsfield-demos.py --workdir ~/demos                      # download once + encode, nothing uploaded
  python3 scripts/higgsfield-demos.py --workdir ~/demos --bucket <cards bucket> --upload
  python3 scripts/higgsfield-demos.py --coverage                             # program exercises still without a clip

For each exercise, in order:
  1. download   <workdir>/raw/<slug>.mp4 from Higgsfield, only if it isn't there yet (sources are never hotlinked);
  2. encode     <workdir>/out/<slug>.mp4 with the exercise-demo skill's encode.py (720x720 square, 30fps, H.264,
                no audio, faststart, seamless loop), its first frame as the poster <workdir>/out/<slug>.jpg, and a
                contact sheet <workdir>/sheets/<slug>.jpg to check form;
  3. upload     (only with --upload) both to exercises/demos/ in the bucket behind the site's /exercises/* route,
                then add the slug to Resources/Seed/exercise-demos.json so the app shows it.

Look at every contact sheet before --upload: a clip that teaches bad form is worse than none. Skip a bad one with
--only, or drop it from the batch file. `--source-dir` reads already-downloaded clips (named <slug>.mp4) instead.
"""
import argparse, json, os, shutil, subprocess, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BATCH = os.path.join(ROOT, 'scripts/demos/higgsfield-batch-1.json')
LISTED = os.path.join(ROOT, 'Resources/Seed/exercise-demos.json')
PROGRAMS = os.path.join(ROOT, 'Resources/Seed/exercise-videos.json')
ENCODE = os.path.join(ROOT, '.claude/skills/exercise-demo/scripts/encode.py')
TOO_BIG_KB = 900


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', *args], check=True)


def download(demo, raw, source_dir):
    path = os.path.join(raw, f"{demo['slug']}.mp4")
    if os.path.exists(path):
        return path
    if source_dir:
        shutil.copyfile(os.path.join(source_dir, f"{demo['slug']}.mp4"), path)
    else:
        print(f"  downloading {demo['id']}")
        with urllib.request.urlopen(demo['source'], timeout=120) as response, open(path + '.part', 'wb') as out:
            shutil.copyfileobj(response, out)
        os.replace(path + '.part', path)
    return path


def encode(slug, raw_path, out, sheets):
    subprocess.run([sys.executable, ENCODE, raw_path, out], check=True)
    # encode.py writes its contact sheet as <slug>.jpg; that name is the poster's on the site, so move the sheet.
    os.replace(os.path.join(out, f'{slug}.jpg'), os.path.join(sheets, f'{slug}.jpg'))
    clip = os.path.join(out, f'{slug}.mp4')
    ffmpeg('-i', clip, '-frames:v', '1', '-q:v', '4', os.path.join(out, f'{slug}.jpg'))
    kb = os.path.getsize(clip) // 1024
    if kb > TOO_BIG_KB:
        print(f'  warning: {slug}.mp4 is {kb} KB (aim for 300-600)')
    return clip


def upload(slug, out, bucket):
    for name, kind in ((f'{slug}.mp4', 'video/mp4'), (f'{slug}.jpg', 'image/jpeg')):
        subprocess.run(['aws', 's3', 'cp', os.path.join(out, name), f's3://{bucket}/exercises/demos/{name}',
                        '--content-type', kind, '--cache-control', 'public, max-age=31536000'], check=True)


def write_listed(slugs):
    current = set(json.load(open(LISTED))) if os.path.exists(LISTED) else set()
    with open(LISTED, 'w') as f:
        json.dump(sorted(current | set(slugs)), f, indent=2)
        f.write('\n')


def coverage(demos):
    have = {d['slug'] for d in demos} | (set(json.load(open(LISTED))) if os.path.exists(LISTED) else set())
    return sorted(set(json.load(open(PROGRAMS))) - have)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--workdir', help='where raw/, out/ and sheets/ go (outside the repo)')
    p.add_argument('--source-dir', help='use clips already downloaded here, named <slug>.mp4')
    p.add_argument('--only', help='comma-separated slugs')
    p.add_argument('--bucket', help='the S3 bucket behind the site\'s /exercises/* route')
    p.add_argument('--upload', action='store_true', help='upload, then list the slugs in exercise-demos.json')
    p.add_argument('--coverage', action='store_true', help='print program exercises with no clip, and stop')
    a = p.parse_args()

    demos = json.load(open(BATCH))['demos']
    if a.coverage:
        print('\n'.join(coverage(demos)))
        return
    if not a.workdir:
        p.error('--workdir is required')
    if a.upload and not a.bucket:
        p.error('--upload needs --bucket')
    if a.only:
        wanted = set(a.only.split(','))
        demos = [d for d in demos if d['slug'] in wanted]

    dirs = {k: os.path.join(os.path.expanduser(a.workdir), k) for k in ('raw', 'out', 'sheets')}
    for d in dirs.values():
        os.makedirs(d, exist_ok=True)
    shipped = []
    for demo in demos:
        slug = demo['slug']
        print(f"{slug} ({demo['name']})" + (f"  note: {demo['note']}" if 'note' in demo else ''))
        encode(slug, download(demo, dirs['raw'], a.source_dir), dirs['out'], dirs['sheets'])
        if a.upload:
            upload(slug, dirs['out'], a.bucket)
            shipped.append(slug)
    if shipped:
        write_listed(shipped)
        print(f'Listed {len(shipped)} in {os.path.relpath(LISTED, ROOT)}. Commit it with the next build.')
    else:
        print(f"Encoded {len(demos)}. Check {dirs['sheets']}, then re-run with --bucket and --upload.")


if __name__ == '__main__':
    main()
