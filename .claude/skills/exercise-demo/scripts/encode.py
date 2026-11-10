#!/usr/bin/env python3
"""Turn one raw Seedance clip into the app's looping demo, and a contact sheet to check it.

  python3 encode.py clips/goblet-squat.mp4 out/                 -> out/goblet-squat.mp4 + out/goblet-squat.jpg

The loop: the last XFADE seconds of the clip fade into its first XFADE seconds, so the final frame is the
first frame and it repeats without a jump. The result is a 720x720 center crop at 30fps, H.264, no audio,
faststart, which plays in AVPlayer from the CDN.
"""
import json, os, subprocess, sys

XFADE = 0.4
SIZE = 720
FPS = 30


def duration(path):
    out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', path],
                         check=True, capture_output=True, text=True).stdout
    return float(json.loads(out)['format']['duration'])


def run(args):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', *args], check=True)


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    slug = os.path.splitext(os.path.basename(src))[0]
    L = duration(src)
    x = XFADE
    norm = f'crop=min(iw\\,ih):min(iw\\,ih),scale={SIZE}:{SIZE}:flags=lanczos,fps={FPS},setsar=1,format=yuv420p'
    fc = (f'[0:v]{norm},split[a][b];'
          f'[a]trim=0:{x:.3f},setpts=PTS-STARTPTS[head];'
          f'[b]trim={x:.3f}:{L:.3f},setpts=PTS-STARTPTS[body];'
          f'[body][head]xfade=transition=fade:duration={x:.3f}:offset={L - 2 * x:.3f}[v]')
    out = os.path.join(outdir, f'{slug}.mp4')
    run(['-i', src, '-filter_complex', fc, '-map', '[v]', '-an', '-c:v', 'libx264', '-preset', 'slow', '-crf', '24',
         '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out])
    sheet = os.path.join(outdir, f'{slug}.jpg')
    run(['-i', out, '-vf', 'fps=2,scale=180:-2,tile=10x1', '-frames:v', '1', sheet])
    print(f'{out} ({os.path.getsize(out) // 1024} KB, {duration(out):.2f}s), sheet {sheet}')


if __name__ == '__main__':
    main()
