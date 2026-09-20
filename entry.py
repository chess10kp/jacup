"""Standalone jacup entry point for PyInstaller.

Invokes the bundled src/main.jac through the jaclang CLI so the packaged
binary behaves exactly like `jac run src/main.jac <args>`, including
exit-status propagation from `jacup exec`. Onefile builds extract data files
under sys._MEIPASS; source builds fall back to the directory holding this
file. Script arguments are appended after the filename; jaclang's `run`
command treats everything after it as REMAINDER script args.
"""

import os
import sys


def ensure_ca_bundle() -> None:
    """Point OpenSSL at the host CA bundle if the default lookup is broken.

    PyInstaller bundles its own libssl whose compiled-in verify paths may not
    exist on the target system (e.g. OPENSSLDIR=/usr/lib/ssl on Arch), which
    makes every HTTPS request fail with CERTIFICATE_VERIFY_FAILED. Setting
    SSL_CERT_FILE is read when urllib creates its SSL context, so doing this
    here fixes downloads without touching the application code.
    """
    if os.environ.get("SSL_CERT_FILE"):
        return
    import ssl

    paths = ssl.get_default_verify_paths()
    if (paths.cafile and os.path.isfile(paths.cafile)) or (
        paths.capath and os.path.isdir(paths.capath)
    ):
        return
    candidates = (
        "/etc/ssl/certs/ca-certificates.crt",  # Debian, Arch, SUSE
        "/etc/pki/tls/certs/ca-bundle.crt",  # Fedora, RHEL
        "/etc/ssl/cert.pem",  # Alpine, FreeBSD
        "/usr/local/share/certs/ca-root-nss.crt",  # older FreeBSD
        "/etc/openssl/certs/ca-certificates.crt",  # NetBSD
    )
    for candidate in candidates:
        if os.path.isfile(candidate):
            os.environ["SSL_CERT_FILE"] = candidate
            return


ensure_ca_bundle()

from jaclang.cli.cli import start_cli  # noqa: E402

base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
main = os.path.join(base, "src", "main.jac")
sys.argv = ["jacup", "run", main] + sys.argv[1:]
start_cli()
