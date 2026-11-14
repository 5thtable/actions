import re
import shutil
import sys
from zipfile import ZipFile


SIGNATURE = re.compile(r"META-INF/(MANIFEST[.]MF|[^/]+[.](SF|RSA|DSA|EC)|SIG-[^/]+)", re.IGNORECASE)


def strip_signature(source, destination):
    with ZipFile(source) as bundle, ZipFile(destination, "x") as unsigned:
        for entry in bundle.infolist():
            if SIGNATURE.fullmatch(entry.filename):
                continue
            with bundle.open(entry) as payload, unsigned.open(entry, "w") as output:
                shutil.copyfileobj(payload, output)


if __name__ == "__main__":
    strip_signature(*sys.argv[1:])
