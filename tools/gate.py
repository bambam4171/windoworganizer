#!/usr/bin/env python3
"""Window Organizer gate: swift build of every product, the WOChecks suite (core and editor), the app's own
--ui-smoke run under a fresh state folder in /private/tmp, then the tools checks (Python).

    /usr/bin/python3 tools/gate.py check [--log PATH] [--build-dir DIR]

The whole output goes to the log (default gate-logs/gate-<head>.log, -FAILED on a red run), never to the terminal.
Stdout gets one `gate:` line with the totals, then the log's trailer: # HEAD / # clean / # base, the same three
on one line ("# HEAD h clean yes base b", what the hand-in check reads), and # exit
(base = merge-base with main). Exit 0 only when the build and every check pass.
"""
import argparse
import re
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def steps(build_dir):
    scratch = ['--scratch-path', str(build_dir)]
    return [
        ('build', ['swift', 'build', *scratch, '--product', 'WindowOrganizer']),
        ('build-checks', ['swift', 'build', *scratch, '--product', 'WOChecks']),
        ('checks', [str(build_dir / 'debug/WOChecks')]),
        ('ui-smoke', [str(build_dir / 'debug/WindowOrganizer'), '--ui-smoke']),
        ('tools-checks', [sys.executable, 'tools/check_tools.py']),
    ]


def git(*args):
    r = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, text=True)
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('command', choices=['check'])
    ap.add_argument('--log', help='log path (default gate-logs/gate-<head>.log)')
    ap.add_argument('--build-dir', type=Path, default=ROOT / '.build')
    args = ap.parse_args()

    head = git('rev-parse', 'HEAD') or 'no-head'
    lines, code, summary = [], 0, 'no checks ran'
    state = tempfile.mkdtemp(prefix='wo-gate-', dir='/private/tmp')
    env = dict(os.environ, WO_STATE_DIR=state)
    for name, cmd in steps(args.build_dir):
        r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
        lines.append('## step %s: %s · exit %d' % (name, ' '.join(cmd), r.returncode))
        lines.append(r.stdout + r.stderr)
        if name == 'checks':
            m = re.search(r'^(\d+) passed / (\d+) failed$', r.stdout, re.M)
            summary = '%s passed / %s failed' % m.groups() if m else 'no summary line'
        if name == 'ui-smoke':
            m = re.search(r'^UI: (\d+) passed / (\d+) failed$', r.stdout, re.M)
            summary += ' · UI %s passed / %s failed' % m.groups() if m else ' · UI no summary line'
        if name == 'tools-checks':
            m = re.search(r'^Ran (\d+) tests?', r.stderr, re.M)
            summary += ' · tools %s ok' % (m.group(1) if m else '?') if not r.returncode else ''
        if r.returncode:
            code = r.returncode
            if name == 'tools-checks':
                summary += ' · tools failed'
            elif name != 'checks':
                summary = 'step %s failed' % name
            break
    clean = 'yes' if not git('status', '--porcelain') else 'no'
    base = git('merge-base', 'HEAD', 'main') or 'none'
    trailer = ['# HEAD %s' % head, '# clean %s' % clean, '# base %s' % base,
               '# HEAD %s clean %s base %s' % (head, clean, base), '# exit %d' % code]

    if args.log:
        log = Path(args.log)
    else:
        log = ROOT / 'gate-logs' / ('gate-%s%s.log' % (head[:7], '-FAILED' if code else ''))
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text('\n'.join(lines + ['gate: ' + summary] + trailer) + '\n')
    print('gate: %s · log %s' % (summary, log))
    print('\n'.join(trailer))
    return code


if __name__ == '__main__':
    sys.exit(main())
