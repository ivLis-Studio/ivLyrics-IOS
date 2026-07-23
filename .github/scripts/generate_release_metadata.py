#!/usr/bin/env python3

import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path


REPOSITORY = "ivLis-Studio/ivLyrics-IOS"
BUNDLE_IDENTIFIER = "kr.ivlis.ivlyrics.ios"
SOURCE_PATH = Path("altstore-source.json")
TEMPLATE_PATH = Path(".github/release-notes-template.md")
ICON_URL = (
    "https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/"
    "ivLyrics-IOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
)
ALTSTORE_SOURCE_URL = (
    "https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/"
    "altstore-source.json"
)


def run_git(args, allow_fail=False):
    result = subprocess.run(
        ["git", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0 and not allow_fail:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def version_key(tag):
    value = tag[1:] if tag.lower().startswith("v") else tag
    parts = []
    for chunk in re.split(r"[^0-9A-Za-z]+", value):
        if not chunk:
            continue
        parts.append((0, int(chunk)) if chunk.isdigit() else (1, chunk.lower()))
    return parts


def previous_tag(current_tag):
    current_key = version_key(current_tag)
    tags = [
        tag
        for tag in run_git(["tag", "--list", "v*"]).splitlines()
        if tag and tag != current_tag and version_key(tag) < current_key
    ]
    return sorted(tags, key=version_key)[-1] if tags else ""


def resolve_ref(ref):
    if run_git(["rev-parse", "--verify", f"{ref}^{{commit}}"], allow_fail=True):
        return ref
    return "HEAD"


def resolve_commit(ref):
    resolved = run_git(
        ["rev-parse", "--verify", f"{ref}^{{commit}}"], allow_fail=True
    )
    return resolved.splitlines()[0] if resolved else run_git(["rev-parse", "HEAD"])


def release_range(previous, current_ref):
    return f"{previous}..{current_ref}" if previous else current_ref


def git_diff_stat(previous, current_ref):
    range_spec = release_range(previous, current_ref)
    if previous:
        return run_git(["diff", "--stat", range_spec], allow_fail=True)
    return run_git(
        ["diff-tree", "--root", "--stat", "--no-commit-id", current_ref],
        allow_fail=True,
    )


def parse_numstat(text):
    files = []
    for line in text.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        added, deleted, path = parts
        files.append({
            "path": path.strip(),
            "added": int(added) if added.isdigit() else None,
            "deleted": int(deleted) if deleted.isdigit() else None,
        })
    return files


def release_commits(previous, current_ref):
    raw = run_git(
        [
            "log",
            "--no-merges",
            "--pretty=format:%h%x1f%s%x1f%b%x1e",
            release_range(previous, current_ref),
        ],
        allow_fail=True,
    )
    commits = []
    for record in raw.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        parts = record.split("\x1f", 2)
        if len(parts) < 2:
            continue
        commit_hash = parts[0].strip()
        subject = parts[1].strip()
        body = parts[2].strip() if len(parts) > 2 else ""
        files = parse_numstat(
            run_git(["show", "--format=", "--numstat", commit_hash], allow_fail=True)
        )
        commits.append({
            "hash": commit_hash,
            "subject": subject,
            "body": body,
            "files": files,
        })
    if commits:
        return commits
    return [{
        "hash": run_git(["rev-parse", "--short", current_ref], allow_fail=True)
        or "HEAD",
        "subject": "Build and publish the iOS application.",
        "body": "",
        "files": [],
    }]


def commit_evidence(commits):
    blocks = []
    for commit in commits:
        file_lines = []
        for item in commit["files"][:40]:
            if item["added"] is None or item["deleted"] is None:
                stats = "binary"
            else:
                stats = f"+{item['added']}/-{item['deleted']}"
            file_lines.append(f"  - {item['path']} ({stats})")
        if len(commit["files"]) > 40:
            file_lines.append(
                f"  - ... and {len(commit['files']) - 40} more files"
            )
        blocks.append("\n".join([
            f"Commit: {commit['hash']}",
            f"Subject: {commit['subject']}",
            f"Body: {commit['body'][:2000].strip() or '(none)'}",
            "Files:",
            *(file_lines or ["  - (no file stats)"]),
        ]))
    return "\n\n".join(blocks)


def compare_url(current_tag, previous):
    if previous:
        return f"https://github.com/{REPOSITORY}/compare/{previous}...{current_tag}"
    return f"https://github.com/{REPOSITORY}/commits/{current_tag}"


def load_ipa(path):
    if not path.is_file():
        raise RuntimeError(f"IPA file not found: {path}")

    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        info_names = [
            name
            for name in names
            if re.fullmatch(r"Payload/[^/]+[.]app/Info[.]plist", name)
        ]
        if len(info_names) != 1:
            raise RuntimeError("IPA must contain exactly one application Info.plist")
        if any(
            name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name
            for name in names
        ):
            raise RuntimeError("IPA unexpectedly contains signing metadata")
        if any(
            part == "__MACOSX" or part.startswith("._")
            for name in names
            for part in name.split("/")
            if part
        ):
            raise RuntimeError("IPA contains macOS metadata files")
        info = plistlib.loads(archive.read(info_names[0]))

    bundle_id = str(info.get("CFBundleIdentifier") or "")
    version_name = str(info.get("CFBundleShortVersionString") or "")
    build_number = str(info.get("CFBundleVersion") or "")
    minimum_os = str(info.get("MinimumOSVersion") or "")
    supported = info.get("CFBundleSupportedPlatforms") or []
    if bundle_id != BUNDLE_IDENTIFIER:
        raise RuntimeError(f"Unexpected bundle identifier: {bundle_id}")
    if "iPhoneOS" not in supported:
        raise RuntimeError("IPA is not an iOS device build")

    expected_version = os.environ.get("VERSION_NAME", "").strip()
    expected_build = os.environ.get("BUILD_NUMBER", "").strip()
    if expected_version and version_name != expected_version:
        raise RuntimeError(
            f"IPA version is {version_name}, expected {expected_version}"
        )
    if expected_build and build_number != expected_build:
        raise RuntimeError(
            f"IPA build is {build_number}, expected {expected_build}"
        )

    privacy = {
        key: value
        for key, value in info.items()
        if key.startswith("NS")
        and key.endswith("UsageDescription")
        and isinstance(value, str)
        and value.strip()
    }
    return {
        "name": path.name,
        "path": str(path.resolve()),
        "size": path.stat().st_size,
        "sha256": digest,
        "bundleIdentifier": bundle_id,
        "versionName": version_name,
        "buildNumber": build_number,
        "minimumOSVersion": minimum_os,
        "privacy": privacy,
    }


def verify_checksum(ipa, checksum_path):
    if not checksum_path:
        return
    path = Path(checksum_path)
    if not path.is_file():
        raise RuntimeError(f"Checksum file not found: {path}")
    expected = path.read_text(encoding="utf-8").split(maxsplit=1)[0].lower()
    if expected != ipa["sha256"]:
        raise RuntimeError("IPA checksum file does not match the IPA")


def parse_commit_subject(subject):
    match = re.match(
        r"^(?P<type>build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)"
        r"(?:\([^)]+\))?!?:\s*",
        subject,
        re.IGNORECASE,
    )
    if not match:
        return "", subject.strip()
    return match.group("type").lower(), subject[match.end():].strip()


def fallback_category(subject):
    value = subject.lower()
    if re.search(
        r"lyrics?|translation|pronunciation|cultural|provider|paxsenix|"
        r"instrumental|karaoke|overlay|language",
        value,
    ):
        return "lyrics"
    if re.search(
        r"playback|now playing|vinyl|\blp\b|player|video|scroll|track|spotify dj",
        value,
    ):
        return "playback"
    if re.search(r"\bui\b|dialog|notice|popup|settings?|layout|design", value):
        return "ui"
    return "maintenance"


def fallback_item(commit, language):
    commit_type, text = parse_commit_subject(commit["subject"])
    files = commit["files"]
    additions = sum(item["added"] or 0 for item in files)
    deletions = sum(item["deleted"] or 0 for item in files)
    paths = ", ".join(f"`{item['path']}`" for item in files[:4])
    if len(files) > 4:
        paths += f", +{len(files) - 4}"
    if language == "ko":
        details = (
            f"{len(files)}개 파일에서 +{additions}/-{deletions}줄을 변경했습니다."
            + (f" 주요 범위: {paths}." if paths else "")
        )
    else:
        details = (
            f"Changed {len(files)} files with +{additions}/-{deletions} lines."
            + (f" Main scope: {paths}." if paths else "")
        )
    if commit_type in {"build", "chore", "ci", "docs", "style", "test"}:
        details += (
            " 사용자 기능 외의 유지보수 변경입니다."
            if language == "ko"
            else " This is a maintenance change outside the main user features."
        )
    return {
        "title": text or commit["subject"],
        "details": details,
        "commits": [commit["hash"]],
    }


def fallback_sections(commits, language):
    labels = {
        "ko": {
            "lyrics": "가사, AI 및 오버레이",
            "playback": "재생 및 LP 모드",
            "ui": "UI 및 설정",
            "maintenance": "안정성 및 유지보수",
        },
        "en": {
            "lyrics": "Lyrics, AI, and Overlay",
            "playback": "Playback and LP Mode",
            "ui": "UI and Settings",
            "maintenance": "Reliability and Maintenance",
        },
    }
    grouped = {key: [] for key in labels[language]}
    for commit in commits:
        grouped[fallback_category(commit["subject"])].append(
            fallback_item(commit, language)
        )
    return [
        {"title": labels[language][key], "items": grouped[key]}
        for key in labels[language]
        if grouped[key]
    ]


def fallback_content(current_tag, commits):
    count = len(commits)
    return {
        "ko": {
            "summary": (
                f"{current_tag}는 이전 릴리스 이후의 {count}개 변경을 기능별로 "
                "정리하고 AltStore 설치용 무서명 IPA를 함께 제공하는 업데이트입니다."
            ),
            "sections": fallback_sections(commits, "ko"),
        },
        "en": {
            "summary": (
                f"{current_tag} contains {count} changes since the previous release, "
                "organized by product area and accompanied by an unsigned IPA for AltStore."
            ),
            "sections": fallback_sections(commits, "en"),
        },
    }


def normalize_chat_url(base_url):
    base = (base_url or "").strip().rstrip("/")
    if not base:
        return ""
    if base.endswith("/chat/completions"):
        return base
    if base.endswith("/v1"):
        return base + "/chat/completions"
    return base + "/v1/chat/completions"


def normalize_note_item(item):
    if not isinstance(item, dict):
        return {}
    title = str(item.get("title") or "").strip()
    details = str(item.get("details") or "").strip()
    commit_list = item.get("commits")
    commits = (
        [str(value).strip() for value in commit_list if str(value).strip()]
        if isinstance(commit_list, list)
        else []
    )
    if not title or not details or not commits:
        return {}
    return {"title": title, "details": details, "commits": commits}


def normalize_note_section(section):
    if not isinstance(section, dict):
        return {}
    sections = []
    for group in section.get("sections") or []:
        if not isinstance(group, dict):
            continue
        title = str(group.get("title") or "").strip()
        items = []
        for item in group.get("items") or []:
            normalized = normalize_note_item(item)
            if normalized:
                items.append(normalized)
        if title and items:
            sections.append({"title": title, "items": items})
    return {
        "summary": str(section.get("summary") or "").strip(),
        "sections": sections,
    }


def covered_commits(section):
    return [
        commit
        for group in section.get("sections") or []
        for item in group.get("items") or []
        for commit in item.get("commits") or []
    ]


def has_complete_commit_coverage(content, commits):
    expected = [commit["hash"] for commit in commits]
    if not expected:
        return False
    for language in ("ko", "en"):
        actual = covered_commits(content.get(language) or {})
        if len(actual) != len(expected) or set(actual) != set(expected):
            return False
    return True


def parse_ai_json(text, commits):
    value = (text or "").strip()
    value = re.sub(r"^```(?:json)?\s*", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\s*```$", "", value)
    try:
        data = json.loads(value)
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}
    ko = data.get("ko") if isinstance(data.get("ko"), dict) else {}
    en = data.get("en") if isinstance(data.get("en"), dict) else {}
    if not ko or not en:
        return {}
    content = {
        "ko": normalize_note_section(ko),
        "en": normalize_note_section(en),
    }
    if not has_complete_commit_coverage(content, commits):
        return {}
    return content


def ai_release_content(current_tag, previous, ipa, commits, stat_text):
    api_key = os.environ.get("AI_API_KEY", "").strip()
    api_url = normalize_chat_url(os.environ.get("AI_BASE_URL", ""))
    model = os.environ.get("AI_MODEL", "").strip() or "gpt-4o-mini"
    try:
        timeout_seconds = int(os.environ.get("AI_TIMEOUT_SECONDS", "300"))
    except ValueError:
        timeout_seconds = 300
    timeout_seconds = min(max(timeout_seconds, 60), 900)
    if not api_key or not api_url:
        return {}

    prompt = textwrap.dedent(
        f"""
        You write bilingual GitHub release note content for an iOS music lyrics app named ivLyrics iOS.
        Return JSON only. Do not return Markdown.

        Current tag: {current_tag}
        Previous tag: {previous or "(none)"}
        Compare URL: {compare_url(current_tag, previous)}
        iOS version: {ipa["versionName"]}
        iOS build: {ipa["buildNumber"]}
        IPA asset: {ipa["name"]} ({ipa["size"]} bytes, sha256={ipa["sha256"]})

        Output JSON schema:
        {{
          "ko": {{
            "summary": "Korean summary in two to four sentences",
            "sections": [
              {{
                "title": "Korean product-area heading",
                "items": [
                  {{
                    "title": "Short Korean change title",
                    "details": "One to three detailed Korean sentences describing behavior, conditions, and user impact.",
                    "commits": ["short commit hash"]
                  }}
                ]
              }}
            ]
          }},
          "en": {{
            "summary": "Equivalent English summary in two to four sentences",
            "sections": [
              {{
                "title": "Equivalent English product-area heading",
                "items": [
                  {{
                    "title": "Short English change title",
                    "details": "One to three detailed English sentences describing behavior, conditions, and user impact.",
                    "commits": ["same short commit hash"]
                  }}
                ]
              }}
            ]
          }}
        }}

        Requirements:
        - Write both Korean and English.
        - Keep Korean and English sections semantically equivalent.
        - Compare this release against the previous tag.
        - Create descriptive product-area sections such as Lyrics and AI, Playback and LP Mode, UI and Settings, or Reliability. Use only sections supported by the changes.
        - Cover every supplied commit hash exactly once in Korean and exactly once in English. Equivalent items in both languages must list the same hashes.
        - Combine commits only when they are tightly related parts of one user-facing change. Do not cap the number of sections or items.
        - Make every details field explain what changed, when it matters, and what the user will notice. Include defaults, compatibility behavior, localization, cache handling, and edge cases when supported.
        - Put user-facing changes first and maintenance changes last.
        - The template already explains that the IPA is unsigned and intended for user-side signing with AltStore, so do not duplicate installation instructions inside the change sections.
        - Do not invent changes not supported by the commit evidence.
        - Do not mention secrets, private URLs, internal endpoints, or a Full Changelog link.

        Commit evidence:
        {commit_evidence(commits)}

        Aggregate diff stat:
        {stat_text or "(no diff stat)"}
        """
    ).strip()
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Generate accurate, detailed, and complete release notes from "
                    "git evidence. Never omit a supplied commit."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.15,
    }
    request = urllib.request.Request(
        api_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "ivLyrics-iOS-ReleaseBot/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace").strip()
        if len(body) > 1200:
            body = body[:1200] + "...(truncated)"
        detail = f"HTTP {exc.code}: {exc.reason or ''}".strip()
        if body:
            detail += f" / {body}"
        print(f"AI release note generation failed: {detail}", file=sys.stderr)
        return {}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"AI release note generation failed: {exc}", file=sys.stderr)
        return {}

    choices = data.get("choices") or []
    if not choices:
        return {}
    message = choices[0].get("message") or {}
    return parse_ai_json(message.get("content") or "", commits)


def markdown_sections(sections, fallback_title, fallback_text):
    rendered = []
    for section in sections:
        title = str(section.get("title") or "").strip()
        items = section.get("items") or []
        if not title or not items:
            continue
        bullets = []
        for item in items:
            item_title = str(item.get("title") or "").strip()
            details = str(item.get("details") or "").strip()
            if item_title and details:
                bullets.append(f"- **{item_title}**: {details}")
        if bullets:
            rendered.append(f"### {title}\n" + "\n".join(bullets))
    return "\n\n".join(rendered) or f"### {fallback_title}\n- {fallback_text}"


def load_template():
    if TEMPLATE_PATH.exists():
        return TEMPLATE_PATH.read_text(encoding="utf-8")
    raise RuntimeError(f"Release notes template not found: {TEMPLATE_PATH}")


def render_notes(current_tag, previous, ipa, content):
    ko = content.get("ko") or {}
    en = content.get("en") or {}
    return load_template().format(
        tag=current_tag,
        version_name=ipa["versionName"],
        build_number=ipa["buildNumber"],
        previous_tag=previous or "None",
        compare_url=compare_url(current_tag, previous),
        ko_summary=ko.get("summary") or "릴리스 노트가 생성되었습니다.",
        ko_sections=markdown_sections(
            ko.get("sections") or [],
            "변경 사항",
            "이전 릴리스 이후의 변경 사항을 정리했습니다.",
        ),
        en_summary=en.get("summary") or "Release notes were generated.",
        en_sections=markdown_sections(
            en.get("sections") or [],
            "Changes",
            "Changes since the previous release are listed here.",
        ),
        ipa_name=ipa["name"],
        ipa_sha256=ipa["sha256"],
        altstore_source_url=ALTSTORE_SOURCE_URL,
    )


def default_source():
    return {
        "name": "ivLyrics iOS",
        "subtitle": "Official ivLyrics releases for AltStore Classic.",
        "description": (
            "Spotify 재생 곡의 싱크 가사를 제공하는 ivLyrics iOS 공식 소스입니다. "
            "This is the official AltStore source for ivLyrics iOS."
        ),
        "iconURL": ICON_URL,
        "website": f"https://github.com/{REPOSITORY}",
        "tintColor": "#FF3B7D",
        "featuredApps": [BUNDLE_IDENTIFIER],
        "apps": [],
        "news": [],
    }


def default_app():
    return {
        "name": "ivLyrics",
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "developerName": "ivLis Studio",
        "subtitle": "Synced Spotify lyrics with karaoke effects.",
        "localizedDescription": (
            "Spotify 재생 곡의 싱크 가사, 번역, 발음 및 노래방 효과를 제공하는 "
            "iOS 앱입니다. An iOS lyrics player with synchronized karaoke effects, "
            "translations, and pronunciation guides for Spotify playback."
        ),
        "iconURL": ICON_URL,
        "tintColor": "#FF3B7D",
        "category": "entertainment",
        "versions": [],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }


def load_source():
    if not SOURCE_PATH.is_file():
        return default_source()
    try:
        source = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default_source()
    return source if isinstance(source, dict) else default_source()


def build_altstore_source(current_tag, ipa, content):
    source = load_source()
    defaults = default_source()
    for key, value in defaults.items():
        if key not in source:
            source[key] = value

    apps = source.get("apps") if isinstance(source.get("apps"), list) else []
    app = next(
        (
            item
            for item in apps
            if isinstance(item, dict)
            and item.get("bundleIdentifier") == BUNDLE_IDENTIFIER
        ),
        default_app(),
    )
    app_defaults = default_app()
    for key, value in app_defaults.items():
        if key not in app:
            app[key] = value

    encoded_tag = urllib.parse.quote(current_tag, safe="")
    encoded_name = urllib.parse.quote(ipa["name"], safe="")
    download_url = (
        f"https://github.com/{REPOSITORY}/releases/download/"
        f"{encoded_tag}/{encoded_name}"
    )
    ko_summary = str((content.get("ko") or {}).get("summary") or "").strip()
    en_summary = str((content.get("en") or {}).get("summary") or "").strip()
    description = "\n\n".join(value for value in [ko_summary, en_summary] if value)
    version = {
        "version": ipa["versionName"],
        "buildVersion": ipa["buildNumber"],
        "date": datetime.now(timezone.utc).date().isoformat(),
        "localizedDescription": description or f"ivLyrics iOS {current_tag}",
        "downloadURL": download_url,
        "size": ipa["size"],
        "sha256": ipa["sha256"],
        "minOSVersion": ipa["minimumOSVersion"] or "17.0",
    }
    versions = app.get("versions") if isinstance(app.get("versions"), list) else []
    versions = [
        item
        for item in versions
        if not (
            isinstance(item, dict)
            and str(item.get("version")) == ipa["versionName"]
            and str(item.get("buildVersion")) == ipa["buildNumber"]
        )
    ]
    app["versions"] = [version, *versions]
    app["appPermissions"] = {
        "entitlements": [],
        "privacy": ipa["privacy"],
    }
    source["apps"] = [app]
    source["news"] = source.get("news") if isinstance(source.get("news"), list) else []
    return source


def write_github_outputs(values):
    output_path = os.environ.get("GITHUB_OUTPUT", "").strip()
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main():
    current_tag = os.environ.get("RELEASE_TAG", "").strip()
    if not current_tag:
        current_tag = run_git(
            ["describe", "--tags", "--exact-match"], allow_fail=True
        )
    if not current_tag:
        raise RuntimeError("RELEASE_TAG is required")

    ipa_path = Path(os.environ.get("IPA_PATH", "").strip())
    ipa = load_ipa(ipa_path)
    verify_checksum(ipa, os.environ.get("CHECKSUM_PATH", "").strip())

    previous = previous_tag(current_tag)
    current_ref = resolve_ref(current_tag)
    stat_text = git_diff_stat(previous, current_ref)
    commits = release_commits(previous, current_ref)
    content = ai_release_content(
        current_tag, previous, ipa, commits, stat_text
    ) or fallback_content(current_tag, commits)
    notes = render_notes(current_tag, previous, ipa, content)
    source = build_altstore_source(current_tag, ipa, content)

    out_dir = Path(os.environ.get("RELEASE_METADATA_DIR", "release-metadata"))
    out_dir.mkdir(parents=True, exist_ok=True)
    notes_path = out_dir / "release-notes.md"
    version_path = out_dir / f"ivLyrics-IOS-{current_tag}-version.json"
    source_path = out_dir / "altstore-source.json"

    notes_path.write_text(notes.strip() + "\n", encoding="utf-8")
    version_path.write_text(
        json.dumps(
            {
                "tag": current_tag,
                "commit": resolve_commit(current_tag),
                "previousTag": previous,
                "versionName": ipa["versionName"],
                "versionCode": int(ipa["buildNumber"]),
                "compareUrl": compare_url(current_tag, previous),
                "altStoreSourceUrl": ALTSTORE_SOURCE_URL,
                "commitCount": len(commits),
                "coveredCommits": [commit["hash"] for commit in commits],
                "ipas": [
                    {
                        "name": ipa["name"],
                        "size": ipa["size"],
                        "sha256": ipa["sha256"],
                        "downloadUrl": source["apps"][0]["versions"][0]["downloadURL"],
                    }
                ],
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    source_path.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_github_outputs(
        {
            "notes_path": notes_path.resolve(),
            "version_path": version_path.resolve(),
            "altstore_source_path": source_path.resolve(),
        }
    )
    print(f"previous_tag={previous}")
    print(f"notes={notes_path}")
    print(f"version_file={version_path}")
    print(f"altstore_source={source_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Release metadata generation failed: {exc}", file=sys.stderr)
        raise
