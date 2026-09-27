"""Bundle and sign WindowOrganizer.app (WO-S2, plan §5).

    /usr/bin/python3 tools/make_app.py [--app PATH] [--version 0.2]

macOS ties the "Device Control and Data Access" grant to the app's signature. An ad-hoc signature is a hash of one
build, so every rebuild needs a new grant (spike limit 2). When the local identity "WindowOrganizer Local" exists
(tools/make_local_identity.py --create, Tom's one-time step) the app is signed with it and the grant survives
rebuilds; otherwise it is signed ad hoc and this says so.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = Path.home() / 'DevOps/Dev/.state/WindowOrganizer/WindowOrganizer.app'
IDENTITY = 'WindowOrganizer Local'
BUNDLE_ID = 'local.windoworganizer.app'

PLIST = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>%(id)s</string>
<key>CFBundleName</key><string>Window Organizer</string>
<key>CFBundleExecutable</key><string>WindowOrganizer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>%(version)s</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
'''


def info_plist(version):
    return PLIST % {'id': BUNDLE_ID, 'version': version}


def choose_identity(listing):
    """The local identity when `security find-identity -v -p codesigning` lists it by its exact name, else ad hoc."""
    return IDENTITY if '"%s"' % IDENTITY in listing else '-'


def sign_command(app, identity):
    return ['/usr/bin/codesign', '--force', '--sign', identity, str(app)]


def bundle(binary, app, version):
    """Copy the binary into the bundle. The old executable is removed first: copying over a binary that is
    running (or cached by the kernel) in place gets the new one killed at launch."""
    macos = Path(app) / 'Contents' / 'MacOS'
    macos.mkdir(parents=True, exist_ok=True)
    exe = macos / 'WindowOrganizer'
    if exe.exists():
        exe.unlink()
    shutil.copy2(binary, exe)
    (Path(app) / 'Contents' / 'Info.plist').write_text(info_plist(version))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--app', type=Path, default=APP)
    ap.add_argument('--version', default='0.2')
    args = ap.parse_args()
    subprocess.run(['swift', 'build', '-c', 'release', '--product', 'WindowOrganizer'], cwd=ROOT, check=True)
    bundle(ROOT / '.build' / 'release' / 'WindowOrganizer', args.app, args.version)
    listing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                             capture_output=True, text=True).stdout
    identity = choose_identity(listing)
    subprocess.run(sign_command(args.app, identity), check=True, capture_output=True)
    req = subprocess.run(['/usr/bin/codesign', '--display', '--requirements', '-', str(args.app)],
                         capture_output=True, text=True).stdout.strip()
    print(args.app)
    print(req.splitlines()[-1] if req else 'no requirement')
    if identity == '-':
        print('signed ad hoc: the permission grant will not survive a rebuild. '
              'Tom\'s one-time step: /usr/bin/python3 tools/make_local_identity.py --create')
    return 0


if __name__ == '__main__':
    sys.exit(main())
