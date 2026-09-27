"""Create the local code-signing identity "WindowOrganizer Local" (WO-S2, plan §5). Tom's one-time step.

    /usr/bin/python3 tools/make_local_identity.py            # dry run: prints the steps, runs nothing
    /usr/bin/python3 tools/make_local_identity.py --create   # does them

The approach of Sögumaður's mac_app/make_local_identity.py: a self-signed certificate with the Code Signing extended
key usage gives the app a designated requirement that stays the same across builds, so the "Device Control and Data
Access" grant is kept after a rebuild. Nothing needs Apple or an account.

1. openssl makes a key and a self-signed certificate (10 years), bundled as PKCS#12, in a temp folder.
2. `security import` puts it into the login keychain, with codesign allowed to use the key.
3. `security add-trusted-cert` trusts it for code signing: macOS asks for the login password once, in a dialog.
Then run tools/make_app.py, which picks the identity up by its name.
"""
import argparse
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path

NAME = 'WindowOrganizer Local'
LOGIN_KEYCHAIN = Path.home() / 'Library/Keychains/login.keychain-db'


def make_certificate(folder, name=NAME, run=subprocess.run):
    """Key + self-signed certificate with the Code Signing EKU, returned with a PKCS#12 bundle and its password."""
    folder = Path(folder)
    config = folder / 'openssl.cnf'
    config.write_text(
        '[req]\ndistinguished_name=dn\nx509_extensions=codesign\nprompt=no\n'
        '[dn]\nCN=%s\n'
        '[codesign]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n'
        'basicConstraints=critical,CA:false\nsubjectKeyIdentifier=hash\n' % name
    )
    key, cert, p12 = folder / 'key.pem', folder / 'cert.pem', folder / 'identity.p12'
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', '3650', '-nodes',
         '-keyout', str(key), '-out', str(cert), '-config', str(config)], check=True, capture_output=True)
    password = secrets.token_urlsafe(16)
    # -legacy keeps the PKCS#12 readable by `security import` when openssl is 3.x.
    legacy = ['-legacy'] if b'OpenSSL 3' in run(['openssl', 'version'], capture_output=True).stdout else []
    run(['openssl', 'pkcs12', '-export', *legacy, '-inkey', str(key), '-in', str(cert), '-name', name,
         '-out', str(p12), '-passout', 'pass:' + password], check=True, capture_output=True)
    return cert, p12, password


def keychain_steps(cert, p12, password, keychain):
    return [
        ['security', 'import', str(p12), '-k', str(keychain), '-P', password, '-f', 'pkcs12',
         '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'],
        ['security', 'add-trusted-cert', '-p', 'codeSign', '-k', str(keychain), str(cert)],
    ]


def existing(name, keychain, run=subprocess.run):
    listing = run(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)],
                  capture_output=True, text=True).stdout
    return '"%s"' % name in listing


def main(argv=None, run=subprocess.run):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--name', default=NAME)
    ap.add_argument('--keychain', type=Path, default=LOGIN_KEYCHAIN)
    ap.add_argument('--create', action='store_true', help='really create it (otherwise a dry run)')
    args = ap.parse_args(argv)
    if not args.create:
        steps = [['openssl', 'req', '-x509', '…', '(key + certificate with the Code Signing EKU, in a temp folder)'],
                 *keychain_steps('<cert.pem>', '<identity.p12>', '<one-time password>', args.keychain)]
        return '\n'.join(['dry run, nothing done. With --create these run:'] + ['  ' + ' '.join(s) for s in steps]
                         + ['macOS asks for the login password once (add-trusted-cert).'])
    if existing(args.name, args.keychain, run):
        return 'identity "%s" already exists in %s' % (args.name, args.keychain)
    with tempfile.TemporaryDirectory() as folder:
        cert, p12, password = make_certificate(folder, args.name, run)
        for step in keychain_steps(cert, p12, password, args.keychain):
            run(step, check=True, capture_output=True)
    if not existing(args.name, args.keychain, run):
        sys.exit('"%s" was imported but is not a valid code-signing identity yet.' % args.name)
    return 'identity "%s" created in %s. Now: /usr/bin/python3 tools/make_app.py' % (args.name, args.keychain)


if __name__ == '__main__':
    print(main())
