import argparse
import json
import os
import plistlib
import urllib.error
import urllib.request
from copy import deepcopy
from datetime import datetime, timezone


JSON_FILE = ".github/apps.json"
STATE_RELEASE_TAG = "1.0"

STIKDEBUG_APP_ID = "com.stik.stikdebug"
DEFAULT_APP_NAME = "StikDebug"
IPA_ASSET = "StikDebug.ipa"
CHANNELS = ("stable", "nightly")


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Update the StikDebug AltStore source."
    )
    parser.add_argument(
        "--repository",
        required=True,
        help="GitHub repository in owner/name format.",
    )
    return parser.parse_args()


ARGS = parse_arguments()
REPOSITORY = ARGS.repository
RELEASE_TAG = os.environ.get("RELEASE_TAG", "")
IS_NIGHTLY = os.environ.get("IS_NIGHTLY", "true").strip().lower() != "false"
COMMIT_SHA = os.environ.get("COMMIT_SHA", "")
COMMIT_MESSAGE = os.environ.get("COMMIT_MESSAGE", "").strip()
WORKFLOW_URL = os.environ.get("WORKFLOW_URL", "")


def github_headers():
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "StikDebug27-AltStore-Updater",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def github_get(url):
    request = urllib.request.Request(url, headers=github_headers(), method="GET")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API request failed with HTTP {error.code}: {body}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Unable to connect to GitHub API: {error}") from error


def github_api_get(url):
    return json.loads(github_get(url).decode("utf-8"))


def load_base_json():
    with open(JSON_FILE, "r", encoding="utf-8") as file:
        source = json.load(file)
    if not isinstance(source, dict):
        raise RuntimeError(f"{JSON_FILE} must contain a JSON object at the root.")
    return source


def load_persistent_json():
    url = f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{STATE_RELEASE_TAG}"
    try:
        release = github_api_get(url)
    except RuntimeError as error:
        if "HTTP 404" in str(error):
            print("No existing 1.0 release found.")
            return None
        raise

    for asset in release.get("assets", []):
        if asset.get("name") == "apps.json" and asset.get("browser_download_url"):
            try:
                return json.loads(github_get(asset["browser_download_url"]).decode("utf-8"))
            except json.JSONDecodeError as error:
                raise RuntimeError("The 1.0 apps.json asset is not valid JSON.") from error

    print("The existing 1.0 release contains no apps.json asset.")
    return None


def app_from(source):
    apps = source.get("apps")
    if not isinstance(apps, list) or len(apps) != 1 or not isinstance(apps[0], dict):
        raise RuntimeError(f"{JSON_FILE} must contain exactly one canonical app.")
    app = apps[0]
    if app.get("name") != DEFAULT_APP_NAME or app.get("bundleIdentifier") != STIKDEBUG_APP_ID:
        raise RuntimeError("The canonical app does not match StikDebug's name and bundle identifier.")
    return app


def channel_map(app):
    channels = app.get("releaseChannels")
    if not isinstance(channels, list):
        return {}
    return {
        channel.get("track"): channel
        for channel in channels
        if isinstance(channel, dict) and isinstance(channel.get("track"), str)
    }


def is_current_architecture(source):
    if not isinstance(source, dict):
        return False
    try:
        app = app_from(source)
    except RuntimeError:
        return False
    return all(track in channel_map(app) for track in CHANNELS)


def clean_source_from_base(base, persistent):
    source = deepcopy(base)
    app = app_from(source)
    for key in ("version", "versionDate", "versionDescription", "downloadURL", "size"):
        app.pop(key, None)
    app["versions"] = []
    app["releaseChannels"] = [{"track": track, "releases": []} for track in CHANNELS]
    source["news"] = []

    if not is_current_architecture(persistent):
        if persistent is not None:
            print("Ignoring legacy 1.0 state because it does not use the StikDebug source architecture.")
        return source

    previous = app_from(persistent)
    previous_versions = previous.get("versions", [])
    if previous_versions and isinstance(previous_versions[0], dict):
        app["versions"] = [deepcopy(previous_versions[0])]

    previous_channels = channel_map(previous)
    current_channels = channel_map(app)
    for track in CHANNELS:
        releases = previous_channels[track].get("releases", [])
        if releases and isinstance(releases[0], dict):
            current_channels[track]["releases"] = [deepcopy(releases[0])]
    return source


def release_asset(release, filename):
    for asset in release.get("assets", []):
        if asset.get("name") == filename:
            url = asset.get("browser_download_url")
            size = asset.get("size")
            if isinstance(url, str) and isinstance(size, int):
                return url, size
    raise RuntimeError(f"Asset {filename!r} was not found in release {release.get('tag_name')!r}.")


def app_versions():
    info_path = "Payload/StikDebug.app/Info.plist"
    with open(info_path, "rb") as file:
        info = plistlib.load(file)
    version = info.get("CFBundleShortVersionString")
    build_version = info.get("CFBundleVersion")
    if not isinstance(version, str) or not version:
        raise RuntimeError(f"{info_path} has no valid CFBundleShortVersionString.")
    if not isinstance(build_version, (str, int)) or not str(build_version):
        raise RuntimeError(f"{info_path} has no valid CFBundleVersion.")
    return version, str(build_version)


def release_description(release):
    if not IS_NIGHTLY:
        return (release.get("body") or "").strip()
    lines = [
        f"Nightly build from commit {COMMIT_SHA[:7] or 'unknown'}.",
        COMMIT_MESSAGE or "No commit message available.",
    ]
    if COMMIT_SHA:
        lines.append(f"Commit: https://github.com/{REPOSITORY}/commit/{COMMIT_SHA}")
    if WORKFLOW_URL:
        lines.append(f"Workflow: {WORKFLOW_URL}")
    return "\n\n".join(lines)


def update_source():
    if not RELEASE_TAG:
        raise RuntimeError("RELEASE_TAG is not set.")

    base = load_base_json()
    persistent = load_persistent_json()
    source = clean_source_from_base(base, persistent)
    release = github_api_get(f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{RELEASE_TAG}")
    download_url, size = release_asset(release, IPA_ASSET)
    version, build_version = app_versions()
    date = release.get("published_at") or release.get("created_at") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = {
        "version": version,
        "buildVersion": build_version,
        "date": date,
        "localizedDescription": release_description(release),
        "downloadURL": download_url,
        "size": size,
    }
    if IS_NIGHTLY:
        entry["commit"] = COMMIT_SHA[:7]
        entry["headline"] = COMMIT_MESSAGE

    app = app_from(source)
    channels = channel_map(app)
    if IS_NIGHTLY:
        channels["nightly"]["releases"] = [entry]
    else:
        app["versions"] = [entry]
        channels["stable"]["releases"] = [entry]

    with open(JSON_FILE, "w", encoding="utf-8") as file:
        json.dump(source, file, indent=2, ensure_ascii=False)
        file.write("\n")

    print(f"AltStore source updated: {version} ({build_version}), {'nightly' if IS_NIGHTLY else 'stable'}.")


if __name__ == "__main__":
    update_source()
