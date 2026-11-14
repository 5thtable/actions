import hashlib
import plistlib
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def verify_profile(path, application_id, installed_identities):
    with Path(path).open("rb") as profile_file:
        profile = plistlib.load(profile_file)

    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime) or expires.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("Use a current iOS provisioning profile.")

    team_ids = profile.get("TeamIdentifier", [])
    profile_id = profile.get("UUID", "")
    if len(team_ids) != 1 or not re.fullmatch("[A-Z0-9]{10}", team_ids[0]):
        raise ValueError("The iOS provisioning profile has an invalid team identifier.")
    if not re.fullmatch("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", profile_id):
        raise ValueError("The iOS provisioning profile has an invalid UUID.")
    team_id = team_ids[0]
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("application-identifier") != f"{team_id}.{application_id}":
        raise ValueError("The iOS provisioning profile must match the app bundle ID.")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") or entitlements.get("get-task-allow"):
        raise ValueError("Use an App Store distribution provisioning profile.")

    fingerprints = {
        hashlib.sha1(certificate, usedforsecurity=False).hexdigest()
        for certificate in profile.get("DeveloperCertificates", [])
    }
    if not fingerprints.intersection(installed_identities.lower().splitlines()):
        raise ValueError("The iOS provisioning profile does not cover the installed distribution certificate.")
    print(team_id, profile_id)


if __name__ == "__main__":
    verify_profile(*sys.argv[1:])
