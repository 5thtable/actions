import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import PurePosixPath
from zipfile import ZipFile


def verify_manifest(manifest_path, application_id, build_number):
    manifest = ET.parse(manifest_path).getroot()
    android = "{http://schemas.android.com/apk/res/android}"
    if manifest.get("package") != application_id:
        raise ValueError("The Android bundle has an unexpected package.")
    if manifest.get(android + "versionCode") != build_number:
        raise ValueError("The Android bundle has an unexpected version code.")
    version_name = manifest.get(android + "versionName", "")
    if not re.fullmatch(rf"[0-9]+[.][0-9]+[.]{re.escape(build_number)}", version_name):
        raise ValueError("The Android version name does not match the requested build.")
    sdk = manifest.find("uses-sdk")
    if sdk is None or int(sdk.get(android + "targetSdkVersion", "0")) < 36:
        raise ValueError("The Android bundle must target at least API 36.")
    application = manifest.find("application")
    if application is None or application.get(android + "debuggable") not in (None, "false"):
        raise ValueError("The Android bundle must have a non-debuggable application.")
    return version_name


def verify_native_libraries(bundle_path):
    with ZipFile(bundle_path) as bundle:
        libraries = [
            path for path in bundle.namelist() if re.fullmatch(r"[^/]+/lib/[^/]+/[^/]+[.]so", path)
        ]
        library_names = {PurePosixPath(path).name for path in libraries}
        if not {"libil2cpp.so", "libunity.so"} <= library_names:
            raise ValueError("The Android bundle is missing the Unity IL2CPP libraries.")
        for path in libraries:
            if PurePosixPath(path).parent.name != "arm64-v8a":
                raise ValueError(f"Unexpected Android architecture: {path}")
            verify_alignment(bundle.read(path), path)


def verify_alignment(library, path):
    if library[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", library, 18)[0] != 183:
        raise ValueError(f"Expected a 64-bit ARM ELF file: {path}")
    table_offset = struct.unpack_from("<Q", library, 32)[0]
    entry_size, entry_count = struct.unpack_from("<HH", library, 54)
    load_segments = []
    for index in range(entry_count):
        segment = struct.unpack_from("<IIQQQQQQ", library, table_offset + entry_size * index)
        if segment[0] == 1:
            load_segments.append(segment)
    if not load_segments or any(
        segment[7] < 16384 or (segment[3] - segment[2]) % 16384
        for segment in load_segments
    ):
        raise ValueError(f"ELF load segments are not 16 KB aligned: {path}")


if __name__ == "__main__":
    bundle, manifest, application_id, build_number = sys.argv[1:]
    version = verify_manifest(manifest, application_id, build_number)
    verify_native_libraries(bundle)
    print(version)
