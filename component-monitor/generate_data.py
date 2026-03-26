#!/usr/bin/env python3
"""
Generates release health dashboard data by comparing upstream commit SHAs
against downstream head files, fetching build status from GitHub check runs,
looking up image SHAs from project.yaml, and querying Konflux PipelineRun
image SHAs via opc results CLI.
"""

import argparse
import base64
import glob
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
REPOS_DIR = REPO_ROOT / "config" / "downstream" / "repos"
RELEASES_DIR = REPO_ROOT / "config" / "downstream" / "releases"
KONFLUX_CONFIG = REPO_ROOT / "config" / "downstream" / "konflux.yaml"
APPS_DIR = REPO_ROOT / "config" / "downstream" / "applications"
OUTPUT_FILE = Path(__file__).resolve().parent / "data.json"

GITHUB_API = "https://api.github.com"
KONFLUX_NAMESPACE = "tekton-ecosystem-tenant"
DEFAULT_IMAGE_PREFIX = "pipelines-"
DEFAULT_IMAGE_SUFFIX = "-rhel9"

SKIP_REPOS_ALWAYS = {"operator-index", "tekton-assist"}
SKIP_REPOS_BEFORE_1_22 = {"tekton-kueue", "multicluster-proxy-aae", "syncer-service"}
ALLOWED_VERSIONS = {"1.15", "1.20", "1.21", "1.22", "next"}
VERSION_1_22 = 1.22
UPSTREAM_BRANCH_OVERRIDES = {
    "git-init": "main",
}

OPC_CMD = os.environ.get("OPC_PATH", "opc")
DESCRIBE_TIMEOUT = 360
DESCRIBE_WORKERS = 10


def hyphenize(s):
    return re.sub(r"[^a-z0-9]", "-", s.lower())


def github_headers():
    token = os.environ.get("GITHUB_TOKEN", "")
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"token {token}"
    return headers


# ---------------------------------------------------------------------------
# Config loaders
# ---------------------------------------------------------------------------

def load_repo_configs():
    repos = {}
    for filepath in sorted(glob.glob(str(REPOS_DIR / "*.yaml"))):
        config_key = Path(filepath).stem
        if any(config_key == s or config_key.startswith(s + "-") for s in SKIP_REPOS_ALWAYS):
            continue
        with open(filepath) as f:
            data = yaml.safe_load(f)
        if not data:
            continue
        name = data.get("name", config_key)
        repo = data.get("repo", name)
        upstream = data.get("upstream", "")
        no_prefix_upstream = data.get("no-prefix-upstream", False)

        components = []
        for c in data.get("components", []):
            components.append({
                "name": c.get("name", ""),
                "image_prefix": c.get("image-prefix", ""),
                "no_image_prefix": c.get("no-image-prefix", False),
                "no_image_suffix": c.get("no-image-suffix", False),
                "no_prefix_upstream": c.get("no-prefix-upstream", False),
            })

        repos[config_key] = {
            "name": name,
            "repo": repo,
            "upstream": upstream,
            "no_prefix_upstream": no_prefix_upstream,
            "components": components,
        }
    return repos


def compute_image_name(comp, repo_info):
    upstream = repo_info["upstream"]
    repo_no_prefix = repo_info["no_prefix_upstream"]

    image_prefix = DEFAULT_IMAGE_PREFIX + comp.get("image_prefix", "")
    if not comp.get("no_image_prefix", False):
        if not (comp.get("no_prefix_upstream", False) or repo_no_prefix) and upstream:
            upstream_basename = upstream.split("/")[-1]
            image_prefix += upstream_basename + "-"

    image_name = comp.get("name", "")
    image_suffix = "" if comp.get("no_image_suffix", False) else DEFAULT_IMAGE_SUFFIX

    return f"{image_prefix}{image_name}{image_suffix}"


def load_release_configs():
    releases = {}
    for filepath in sorted(glob.glob(str(RELEASES_DIR / "*.yaml"))):
        version_key = Path(filepath).stem
        if version_key not in ALLOWED_VERSIONS:
            continue
        with open(filepath) as f:
            data = yaml.safe_load(f)
        if not data:
            continue
        version = str(data.get("version", version_key))
        releases[version_key] = {
            "version": version,
            "patch_version": str(data.get("patch-version", "")),
            "code_freeze": data.get("code-freeze", False),
            "branches": data.get("branches", {}),
        }
    return releases


def load_downstream_org():
    with open(KONFLUX_CONFIG) as f:
        data = yaml.safe_load(f)
    return data.get("organization", "openshift-pipelines")


def downstream_branch_name(version):
    try:
        float(version)
        return f"release-v{version}.x"
    except ValueError:
        return version


# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

def get_upstream_latest_sha(upstream_repo, branch, session):
    url = f"{GITHUB_API}/repos/{upstream_repo}/commits/{branch}"
    try:
        resp = session.get(url, headers=github_headers())
        if resp.status_code == 200:
            return resp.json().get("sha", "")
        print(f"  [WARN] upstream {upstream_repo}@{branch}: HTTP {resp.status_code}", file=sys.stderr)
    except requests.RequestException as e:
        print(f"  [ERROR] upstream {upstream_repo}@{branch}: {e}", file=sys.stderr)
    return ""


def get_downstream_head_sha(downstream_org, downstream_repo, branch, session):
    url = f"{GITHUB_API}/repos/{downstream_org}/{downstream_repo}/contents/head"
    params = {"ref": branch}
    try:
        resp = session.get(url, headers=github_headers(), params=params)
        if resp.status_code == 200:
            content = resp.json().get("content", "")
            encoding = resp.json().get("encoding", "")
            if encoding == "base64":
                return base64.b64decode(content).decode("utf-8").strip()
            return content.strip()
        print(f"  [WARN] downstream {downstream_org}/{downstream_repo}@{branch}/head: HTTP {resp.status_code}", file=sys.stderr)
    except requests.RequestException as e:
        print(f"  [ERROR] downstream {downstream_org}/{downstream_repo}@{branch}/head: {e}", file=sys.stderr)
    return ""


def get_downstream_commit_sha(downstream_org, downstream_repo, branch, session):
    url = f"{GITHUB_API}/repos/{downstream_org}/{downstream_repo}/commits/{branch}"
    try:
        resp = session.get(url, headers=github_headers())
        if resp.status_code == 200:
            return resp.json().get("sha", "")
        print(f"  [WARN] downstream commit {downstream_org}/{downstream_repo}@{branch}: HTTP {resp.status_code}", file=sys.stderr)
    except requests.RequestException as e:
        print(f"  [ERROR] downstream commit {downstream_org}/{downstream_repo}@{branch}: {e}", file=sys.stderr)
    return ""


def get_check_runs(downstream_org, downstream_repo, commit_sha, session):
    url = f"{GITHUB_API}/repos/{downstream_org}/{downstream_repo}/commits/{commit_sha}/check-runs"
    all_runs = []
    page = 1
    while True:
        try:
            resp = session.get(url, headers=github_headers(), params={"per_page": 100, "page": page})
            if resp.status_code != 200:
                print(f"  [WARN] check runs {downstream_org}/{downstream_repo}@{commit_sha}: HTTP {resp.status_code}", file=sys.stderr)
                break
            data = resp.json()
            runs = data.get("check_runs", [])
            all_runs.extend(runs)
            if len(runs) < 100:
                break
            page += 1
        except requests.RequestException as e:
            print(f"  [ERROR] check runs: {e}", file=sys.stderr)
            break
    return all_runs


# ---------------------------------------------------------------------------
# project.yaml helpers
# ---------------------------------------------------------------------------

def get_project_yaml(downstream_org, branch, session):
    """Fetch project.yaml. Returns (entries_list, raw_text, github_blob_url)."""
    url = f"{GITHUB_API}/repos/{downstream_org}/operator/contents/project.yaml"
    params = {"ref": branch}
    blob_url = f"https://github.com/{downstream_org}/operator/blob/{branch}/project.yaml"
    try:
        resp = session.get(url, headers=github_headers(), params=params)
        if resp.status_code == 200:
            content = resp.json().get("content", "")
            encoding = resp.json().get("encoding", "")
            if encoding == "base64":
                raw = base64.b64decode(content).decode("utf-8")
            else:
                raw = content
            data = yaml.safe_load(raw)
            entries = []
            if isinstance(data, list):
                entries = data
            elif isinstance(data, dict):
                entries = data.get("images", data.get("params", []))
            return entries, raw, blob_url
        print(f"  [WARN] project.yaml {downstream_org}/operator@{branch}: HTTP {resp.status_code}", file=sys.stderr)
    except requests.RequestException as e:
        print(f"  [ERROR] project.yaml: {e}", file=sys.stderr)
    except yaml.YAMLError as e:
        print(f"  [ERROR] parsing project.yaml: {e}", file=sys.stderr)
    return [], "", blob_url


def find_image_in_project_yaml(image_name, project_yaml_entries, raw_text, blob_url):
    """Find image in project.yaml. Returns (ref, digest, github_line_url)."""
    if not image_name or not project_yaml_entries:
        return "", "", ""

    for entry in project_yaml_entries:
        value = entry.get("value", "")
        if not value:
            continue
        entry_base = value.split("@")[0].split(":")[0].rsplit("/", 1)[-1]
        if entry_base == image_name:
            digest = ""
            if "@sha256:" in value:
                digest = value.split("@")[1]
            line_url = ""
            if raw_text and blob_url:
                for i, line in enumerate(raw_text.splitlines(), 1):
                    if image_name in line and ("@sha256:" in line or "value:" in line):
                        line_url = f"{blob_url}#L{i}"
                        break
            return value, digest, line_url
    return "", "", ""


# ---------------------------------------------------------------------------
# Konflux PipelineRun helpers (opc results + oc)
# ---------------------------------------------------------------------------

def load_app_repo_mapping():
    """Load application configs and build a repo -> application-name mapping."""
    mapping = {}
    for f in sorted(APPS_DIR.glob("*.yaml")):
        with open(f) as fh:
            apps = yaml.safe_load(fh)
        if not isinstance(apps, list):
            continue
        for app in apps:
            app_name = app.get("name", "")
            for repo in app.get("repos", []):
                mapping[repo] = app_name
    return mapping


def get_konflux_ui_url():
    """Derive the Konflux UI base URL from the OpenShift console URL."""
    try:
        result = subprocess.run(
            ["oc", "whoami", "--show-console"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            console = result.stdout.strip()
            m = re.search(r"\.apps\.(.+)", console)
            if m:
                return f"https://konflux-ui.apps.{m.group(1)}"
    except Exception:
        pass
    return ""


def pipelinerun_url(konflux_ui_url, pr_name, app_name, version,
                    namespace=KONFLUX_NAMESPACE):
    """Construct the Konflux UI URL for a PipelineRun."""
    if not konflux_ui_url or not pr_name or not app_name:
        return ""
    versioned_app = f"{app_name}-{hyphenize(version)}"
    return (f"{konflux_ui_url}/ns/{namespace}/applications/"
            f"{versioned_app}/pipelineruns/{pr_name}")


def setup_results_config():
    """Configure opc results CLI using env vars."""
    host = os.environ.get("RESULTS_HOST", "")
    token = os.environ.get("RESULTS_TOKEN", "")
    if not host:
        print("  [WARN] RESULTS_HOST not set, skipping opc results config", file=sys.stderr)
        return False
    cmd = [OPC_CMD, "results", "config", "set",
           f"--host={host}", f"--token={token}", "--insecure-skip-tls-verify"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            print(f"  [WARN] opc results config set failed: {result.stderr.strip()}", file=sys.stderr)
            return False
        print("  opc results configured", file=sys.stderr)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"  [WARN] opc results config: {e}", file=sys.stderr)
        return False


def list_pipelineruns_from_cluster(component_label, namespace=KONFLUX_NAMESPACE):
    """List PipelineRuns from the cluster via oc. Returns list of dicts with
    name, status, source, commit_sha, and creation_ts."""
    try:
        result = subprocess.run(
            ["oc", "get", "pipelinerun", "-n", namespace,
             "-l", f"appstudio.openshift.io/component={component_label}",
             "-o", "json"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return []
        data = json.loads(result.stdout)
        prs = []
        for item in data.get("items", []):
            name = item.get("metadata", {}).get("name", "")
            conditions = item.get("status", {}).get("conditions", [])
            reason = conditions[-1].get("reason", "") if conditions else ""
            labels = item.get("metadata", {}).get("labels", {})
            commit_sha = labels.get("build.appstudio.redhat.com/commit_sha", "")
            creation_ts = item.get("metadata", {}).get("creationTimestamp", "")
            prs.append({
                "name": name, "status": reason, "source": "cluster",
                "commit_sha": commit_sha, "creation_ts": creation_ts,
            })
        return prs
    except Exception:
        return []


def _parse_relative_time(text):
    """Convert relative time like '2d ago', '13h ago', '5m ago' to an ISO timestamp."""
    m = re.match(r"(\d+)([dhms])", text)
    if not m:
        return ""
    value, unit = int(m.group(1)), m.group(2)
    delta = {"d": timedelta(days=value), "h": timedelta(hours=value),
             "m": timedelta(minutes=value), "s": timedelta(seconds=value)}.get(unit)
    if not delta:
        return ""
    return (datetime.now(timezone.utc) - delta).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_pipelineruns_from_results(component_label, namespace=KONFLUX_NAMESPACE):
    """List PipelineRuns from Tekton Results via opc. Returns list of dicts with
    name, status, source, commit_sha, and creation_ts parsed from STARTED column."""
    try:
        result = subprocess.run(
            [OPC_CMD, "results", "pipelinerun", "list",
             "-n", namespace,
             "-L", f"appstudio.openshift.io/component={component_label}",
             "--limit", "10"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return []
        lines = result.stdout.strip().split("\n")
        if len(lines) <= 1:
            return []
        prs = []
        for line in lines[1:]:
            parts = line.split()
            if len(parts) < 2:
                continue
            started = ""
            for i, p in enumerate(parts):
                if p == "ago" and i >= 2:
                    started = _parse_relative_time(parts[i - 1])
                    break
            prs.append({
                "name": parts[0], "status": parts[-1], "source": "results",
                "commit_sha": "", "creation_ts": started,
            })
        return prs
    except Exception:
        return []


def find_latest_onpush_and_ec(pipelineruns):
    """From a merged PLR list (already most-recent-first), find:
    1. The latest created on-push build PLR (any status)
    2. The EC PLR sharing the same build.appstudio.redhat.com/commit_sha
    Returns (on_push_pr, ec_pr) where each is a dict or None."""
    on_push = None
    for pr in pipelineruns:
        if "on-push" in pr["name"]:
            on_push = pr
            break

    ec_check = None
    if on_push:
        target_sha = on_push.get("commit_sha", "")
        for pr in pipelineruns:
            if "enterprise-contract" not in pr["name"]:
                continue
            if target_sha and pr.get("commit_sha") == target_sha:
                ec_check = pr
                break
            elif not target_sha:
                ec_check = pr
                break

    return on_push, ec_check


def list_and_find_pr(component_label):
    """List PLRs from both cluster and results, deduplicate, sort by
    creation_ts (most-recent-first), find latest on-push and matching EC.

    Cluster entries are preferred during dedup because they carry
    commit_sha metadata.  Both sources now provide creation_ts so a
    single timestamp sort determines the definitive order.
    """
    cluster_prs = list_pipelineruns_from_cluster(component_label)
    results_prs = list_pipelineruns_from_results(component_label)

    cluster_lookup = {pr["name"]: pr for pr in cluster_prs}

    seen = set()
    merged = []
    for pr in results_prs:
        name = pr["name"]
        if name not in seen:
            seen.add(name)
            if name in cluster_lookup:
                entry = cluster_lookup[name]
                if not entry.get("creation_ts") and pr.get("creation_ts"):
                    entry["creation_ts"] = pr["creation_ts"]
                merged.append(entry)
            else:
                merged.append(pr)
    for pr in cluster_prs:
        if pr["name"] not in seen:
            seen.add(pr["name"])
            merged.append(pr)

    merged.sort(key=lambda p: p.get("creation_ts", ""), reverse=True)

    on_push, ec_check = find_latest_onpush_and_ec(merged)
    return on_push, ec_check, merged


def describe_pipelinerun(pr_name, namespace=KONFLUX_NAMESPACE):
    """Get image SHA from a PipelineRun. Tries cluster first (fast), then opc results (slow)."""
    image_url, image_digest = "", ""

    # Try cluster first (fast, ~1-2s)
    try:
        result = subprocess.run(
            ["oc", "get", "pipelinerun", pr_name, "-n", namespace, "-o", "json"],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            for r in data.get("status", {}).get("results", []):
                if r.get("name") == "IMAGE_URL":
                    image_url = r.get("value", "")
                elif r.get("name") == "IMAGE_DIGEST":
                    image_digest = r.get("value", "")
            if image_url and image_digest:
                return {"image_url": image_url, "image_digest": image_digest,
                        "pipelinerun_name": pr_name, "source": "cluster"}
    except Exception:
        pass

    # Fall back to opc results describe (slow, ~3-5min)
    try:
        print(f"    [INFO] Fetching from Results API: {pr_name} (this may take a few minutes)", file=sys.stderr)
        result = subprocess.run(
            [OPC_CMD, "results", "pipelinerun", "describe", pr_name,
             "-n", namespace, "-o", "json"],
            capture_output=True, text=True, timeout=DESCRIBE_TIMEOUT,
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            for r in data.get("status", {}).get("results", []):
                if r.get("name") == "IMAGE_URL":
                    image_url = r.get("value", "")
                elif r.get("name") == "IMAGE_DIGEST":
                    image_digest = r.get("value", "")
            if image_url or image_digest:
                return {"image_url": image_url, "image_digest": image_digest,
                        "pipelinerun_name": pr_name, "source": "results"}
    except subprocess.TimeoutExpired:
        print(f"    [WARN] opc results describe timed out for {pr_name}", file=sys.stderr)
    except Exception as e:
        print(f"    [WARN] opc results describe failed for {pr_name}: {e}", file=sys.stderr)

    return {}


# ---------------------------------------------------------------------------
# Build status helpers
# ---------------------------------------------------------------------------

def build_pipelinerun_name(repo_name, version, component_name):
    base = repo_name.rsplit("/", 1)[-1] if "/" in repo_name else repo_name
    return f"{hyphenize(base)}-{hyphenize(version)}-{component_name}-on-push"


def build_component_label(repo_name, version, component_name):
    base = repo_name.rsplit("/", 1)[-1] if "/" in repo_name else repo_name
    return f"{hyphenize(base)}-{hyphenize(version)}-{hyphenize(component_name)}"


def get_component_build_status(check_runs, repo_name, version, component_name):
    expected_pr_name = build_pipelinerun_name(repo_name, version, component_name)
    for cr in check_runs:
        cr_name = cr.get("name", "")
        if expected_pr_name in cr_name:
            return {
                "conclusion": cr.get("conclusion") or "",
                "status": cr.get("status") or "",
                "check_url": cr.get("html_url") or "",
            }
    return {"conclusion": "", "status": "", "check_url": ""}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate Component Monitor dashboard data")
    parser.add_argument("--version", help="Only process this version (e.g. 1.21, next)")
    parser.add_argument("--repos",
                        help="Comma-separated list of repo config keys to process (e.g. tektoncd-pipeline,operator)")
    parser.add_argument("--merge", action="store_true",
                        help="Merge results into existing data.json instead of overwriting")
    parser.add_argument("--enable-konflux", action="store_true",
                        help="Query Konflux for PipelineRun image SHAs (requires oc login + opc results config)")
    args = parser.parse_args()

    repo_configs = load_repo_configs()
    release_configs = load_release_configs()
    downstream_org = load_downstream_org()
    app_repo_map = load_app_repo_mapping()

    if args.version:
        filtered = {k: v for k, v in release_configs.items() if k == args.version}
        if not filtered:
            print(f"Version '{args.version}' not found. Available: {', '.join(release_configs.keys())}", file=sys.stderr)
            sys.exit(1)
        release_configs = filtered

    if args.repos:
        selected = {r.strip() for r in args.repos.split(",")}
        all_keys = set(repo_configs.keys())
        unknown = selected - all_keys
        if unknown:
            print(f"Unknown repo(s): {', '.join(sorted(unknown))}. Available: {', '.join(sorted(all_keys))}", file=sys.stderr)
        repo_configs = {k: v for k, v in repo_configs.items() if k in selected}
        if not repo_configs:
            print("No matching repos found.", file=sys.stderr)
            sys.exit(1)

    print(f"Loaded {len(repo_configs)} repo configs", file=sys.stderr)
    print(f"Processing {len(release_configs)} release(s): {', '.join(release_configs.keys())}", file=sys.stderr)
    print(f"Downstream org: {downstream_org}", file=sys.stderr)
    print(f"Konflux integration: {'enabled' if args.enable_konflux else 'disabled'}", file=sys.stderr)

    konflux_ui_url = ""
    if args.enable_konflux:
        setup_results_config()
        konflux_ui_url = get_konflux_ui_url()
        print(f"Konflux UI URL: {konflux_ui_url}", file=sys.stderr)

    session = requests.Session()
    result = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "downstream_org": downstream_org,
        "konflux_enabled": args.enable_konflux,
        "konflux_ui_url": konflux_ui_url,
        "versions": {},
    }

    for version_key, release in sorted(release_configs.items(), key=lambda x: x[0]):
        version = release["version"]
        ds_branch = downstream_branch_name(version)
        print(f"\n{'='*60}", file=sys.stderr)
        print(f"Processing version {version} (downstream branch: {ds_branch})", file=sys.stderr)

        print(f"  Fetching project.yaml from {downstream_org}/operator@{ds_branch}", file=sys.stderr)
        project_yaml_entries, project_yaml_raw, project_yaml_blob_url = get_project_yaml(
            downstream_org, ds_branch, session
        )
        print(f"  Found {len(project_yaml_entries)} entries in project.yaml", file=sys.stderr)

        components_data = []
        branches = release.get("branches", {})

        # Phase 1: Collect GitHub data + list PLRs
        describe_tasks = {}  # comp_key -> pr_name

        try:
            version_num = float(version)
        except ValueError:
            version_num = float("inf")

        for config_key, repo_info in sorted(repo_configs.items()):
            if version_num < VERSION_1_22 and any(
                config_key == s or config_key.startswith(s + "-") for s in SKIP_REPOS_BEFORE_1_22
            ):
                continue

            upstream_repo = repo_info["upstream"]
            downstream_repo = repo_info["repo"]
            repo_name = repo_info["name"]

            branch_entry = branches.get(config_key)
            if config_key in UPSTREAM_BRANCH_OVERRIDES:
                upstream_branch = UPSTREAM_BRANCH_OVERRIDES[config_key]
            elif branch_entry:
                upstream_branch = branch_entry.get("upstream", ds_branch)
            else:
                upstream_branch = ds_branch

            if upstream_repo:
                print(f"  {config_key}: {upstream_repo}@{upstream_branch} -> {downstream_org}/{downstream_repo}@{ds_branch}", file=sys.stderr)
                upstream_sha = get_upstream_latest_sha(upstream_repo, upstream_branch, session)
                head_sha = get_downstream_head_sha(downstream_org, downstream_repo, ds_branch, session)
                in_sync = bool(upstream_sha and head_sha and upstream_sha == head_sha)
            else:
                print(f"  {config_key}: no upstream (downstream only)", file=sys.stderr)
                upstream_sha = ""
                head_sha = ""
                in_sync = False

            ds_commit = get_downstream_commit_sha(downstream_org, downstream_repo, ds_branch, session)
            check_runs = []
            if ds_commit:
                check_runs = get_check_runs(downstream_org, downstream_repo, ds_commit, session)

            component_builds = []
            for comp in repo_info["components"]:
                comp_name = comp["name"]
                comp_label = build_component_label(repo_name, version, comp_name)
                build_info = get_component_build_status(check_runs, repo_name, version, comp_name)

                image_name = compute_image_name(comp, repo_info)
                project_yaml_ref, project_yaml_digest, project_yaml_line_url = find_image_in_project_yaml(
                    image_name, project_yaml_entries, project_yaml_raw, project_yaml_blob_url
                )

                build_entry = {
                    "component": comp_name,
                    "component_label": comp_label,
                    "conclusion": build_info["conclusion"],
                    "status": build_info["status"],
                    "check_url": build_info["check_url"],
                    "image_name": image_name,
                    "project_yaml_ref": project_yaml_ref,
                    "project_yaml_digest": project_yaml_digest,
                    "project_yaml_url": project_yaml_line_url,
                    "konflux_image_url": "",
                    "konflux_image_digest": "",
                    "konflux_pr_name": "",
                    "konflux_pr_url": "",
                    "ec_status": "",
                    "ec_pr_name": "",
                    "ec_pr_url": "",
                    "digest_match": None,
                }

                if args.enable_konflux:
                    print(f"    Listing PLRs for {comp_label}", file=sys.stderr)
                    latest_pr, ec_pr, all_prs = list_and_find_pr(comp_label)
                    on_push_count = sum(1 for p in all_prs if "on-push" in p["name"])
                    ec_count = sum(1 for p in all_prs if "enterprise-contract" in p["name"])
                    print(f"      Found {len(all_prs)} PLR(s) ({on_push_count} on-push, {ec_count} EC)", file=sys.stderr)
                    if latest_pr:
                        comp_key = f"{config_key}/{comp_name}"
                        build_entry["conclusion"] = latest_pr["status"].lower()
                        build_entry["konflux_pr_name"] = latest_pr["name"]
                        build_entry["konflux_pr_url"] = pipelinerun_url(
                            konflux_ui_url, latest_pr["name"],
                            app_repo_map.get(config_key, ""), version)
                        print(f"      Latest on-push: {latest_pr['name']} -> {latest_pr['status']} (from {latest_pr['source']})", file=sys.stderr)
                        if latest_pr["status"] == "Succeeded":
                            describe_tasks[comp_key] = latest_pr["name"]
                    else:
                        print(f"      No on-push PLR found", file=sys.stderr)
                    if ec_pr:
                        build_entry["ec_status"] = ec_pr["status"]
                        build_entry["ec_pr_name"] = ec_pr["name"]
                        build_entry["ec_pr_url"] = pipelinerun_url(
                            konflux_ui_url, ec_pr["name"],
                            app_repo_map.get(config_key, ""), version)
                        sha_info = f" (commit_sha={ec_pr.get('commit_sha', '')[:12]})" if ec_pr.get("commit_sha") else ""
                        print(f"      Matched EC check: {ec_pr['name']} -> {ec_pr['status']}{sha_info}", file=sys.stderr)
                    else:
                        print(f"      No matching EC check PLR found", file=sys.stderr)

                component_builds.append(build_entry)

            conclusions = [cb["conclusion"] for cb in component_builds if cb["conclusion"]]
            if not conclusions:
                build_status = "none"
            elif all(c in ("success", "succeeded") for c in conclusions):
                build_status = "success"
            elif any(c in ("failure", "failed") for c in conclusions):
                build_status = "failure"
            elif any(c in ("pending", "in_progress", "running", "") for c in conclusions):
                build_status = "pending"
            else:
                build_status = "unknown"

            components_data.append({
                "name": config_key,
                "upstream_repo": upstream_repo,
                "upstream_branch": upstream_branch,
                "upstream_sha": upstream_sha,
                "downstream_repo": f"{downstream_org}/{downstream_repo}",
                "downstream_branch": ds_branch,
                "head_sha": head_sha,
                "in_sync": in_sync,
                "build_status": build_status,
                "component_builds": component_builds,
            })

        # Phase 2: Parallel describe for all PLRs found
        if args.enable_konflux and describe_tasks:
            print(f"\n  Describing {len(describe_tasks)} PipelineRun(s) in parallel (max {DESCRIBE_WORKERS} workers)...", file=sys.stderr)
            describe_results = {}
            with ThreadPoolExecutor(max_workers=DESCRIBE_WORKERS) as executor:
                futures = {
                    executor.submit(describe_pipelinerun, pr_name): comp_key
                    for comp_key, pr_name in describe_tasks.items()
                }
                for future in as_completed(futures):
                    comp_key = futures[future]
                    try:
                        pr_data = future.result()
                        if pr_data:
                            describe_results[comp_key] = pr_data
                            src = pr_data.get("source", "?")
                            print(f"    [{src}] {comp_key}: {pr_data.get('image_digest', '')[:20]}...", file=sys.stderr)
                        else:
                            print(f"    {comp_key}: no image data", file=sys.stderr)
                    except Exception as e:
                        print(f"    {comp_key}: describe failed: {e}", file=sys.stderr)

            # Merge describe results into component_builds
            for comp_data in components_data:
                for build_entry in comp_data["component_builds"]:
                    comp_key = f"{comp_data['name']}/{build_entry['component']}"
                    if comp_key in describe_results:
                        pr_data = describe_results[comp_key]
                        build_entry["konflux_image_url"] = pr_data.get("image_url", "")
                        build_entry["konflux_image_digest"] = pr_data.get("image_digest", "")
                        build_entry["konflux_pr_name"] = pr_data.get("pipelinerun_name", "")
                        build_entry["konflux_pr_url"] = pipelinerun_url(
                            konflux_ui_url, pr_data.get("pipelinerun_name", ""),
                            app_repo_map.get(comp_data["name"], ""), version
                        )
                        py_digest = build_entry.get("project_yaml_digest", "")
                        k_digest = build_entry["konflux_image_digest"]
                        if py_digest and k_digest:
                            build_entry["digest_match"] = (py_digest == k_digest)

        result["versions"][version_key] = {
            "version": version,
            "patch_version": release["patch_version"],
            "code_freeze": release["code_freeze"],
            "components": components_data,
        }

    if args.merge and OUTPUT_FILE.exists():
        try:
            with open(OUTPUT_FILE) as f:
                existing = json.load(f)
            for vk, vdata in result["versions"].items():
                if vk in existing.get("versions", {}):
                    existing_comps = {c["name"]: c for c in existing["versions"][vk].get("components", [])}
                    for comp in vdata.get("components", []):
                        existing_comps[comp["name"]] = comp
                    vdata["components"] = list(existing_comps.values())
                existing.setdefault("versions", {})[vk] = vdata
            existing["generated_at"] = result["generated_at"]
            existing["konflux_enabled"] = result.get("konflux_enabled", existing.get("konflux_enabled"))
            existing["konflux_ui_url"] = result.get("konflux_ui_url") or existing.get("konflux_ui_url", "")
            result = existing
            print("Merged with existing data.json", file=sys.stderr)
        except (json.JSONDecodeError, KeyError) as e:
            print(f"[WARN] Could not merge existing data.json ({e}), overwriting", file=sys.stderr)

    with open(OUTPUT_FILE, "w") as f:
        json.dump(result, f, indent=2)

    print(f"\nData written to {OUTPUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
