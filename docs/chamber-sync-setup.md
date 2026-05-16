# Chamber Sync Setup

Per-teammate one-time setup for the GitHub Actions self-hosted runner that pushes the repo to your Cadence chamber on every commit to `main`.

## How it works

The chamber's SFTP server (port 222) permits file creates but blocks overwrites and deletes. SSH `exec` is also blocked. Tree-level mirror tools (rsync, lftp mirror) cannot work against this. Solution: **git bundles**.

1. **Automatic upload (push side).** On every push to `main`, GitHub Actions queues one job per teammate listed in the workflow matrix. Each teammate's self-hosted runner (on their Mac) does `git bundle create architecture-<ts>-<sha>.bundle main HEAD` and SFTP-uploads the single bundle file to `~/inbox/architecture-<ts>-<sha>.bundle` on the chamber. The path is unique per push so no overwrite is needed.

2. **Manual promote (chamber side).** When you're ready to refresh `~/architecture/`, open ETX and run `sync-promote`. It picks the newest bundle in `~/inbox/`, runs `git fetch <bundle> main`, and `git reset --hard FETCH_HEAD` to move the current branch and update the working tree. (Fetching directly into the checked-out branch is refused by git, so we land in `FETCH_HEAD` first then reset.) Inside an interactive shell, `git` operates on the working tree via normal Linux syscalls. Bundle objects are content-addressed so fetch only writes new ones into `.git/objects/`.

The "automatic + manual promote" split is what's possible without filing a Cadence support case to lift the SFTP write restriction. Bundles are tiny (a few MB even with full history), so accumulating them in `~/inbox/` is cheap.

| Teammate | Runner label | CHAMBER_USER | CHAMBER_PATH (canonical) |
|---|---|---|---|
| Alan | `longhorn-chamber-alan` | `schwartz` | `/home/schwartz/architecture/` |
| Richard | `longhorn-chamber-richard` | `richuang` | `/home/richuang/architecture/` |
| Chaithu | `longhorn-chamber-chaithu` | `tchaithu` | `/home/tchaithu/architecture/` |

Workflow matrix currently has only `longhorn-chamber-alan` enabled. Richard and Chaithu uncomment their lines in `.github/workflows/sync-chamber.yml` via PR after completing setup.

## Prereqs (per Mac)

```bash
# 1. Homebrew (skip if installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. sshpass (password auth via Keychain)
brew install hudochenkov/sshpass/sshpass

# 3. lftp (SFTP upload engine)
brew install lftp

# 4. git is already on macOS via Xcode CLT, but make sure it's >= 2.0
git --version

# 5. Optional: gh CLI for repo management
brew install gh
```

Chamber side requires `git` (any modern version supports bundles). Verify in an ETX shell:

```bash
git --version
git bundle --help | head -2     # should print man-page synopsis
```

## Step 1 — Install the runner

Get a registration token from GitHub: visit `https://github.com/LonghornSilicon/architecture/settings/actions/runners/new` (requires admin on the repo). Copy the displayed token.

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner

# Check https://github.com/actions/runner/releases for current version
RUNNER_VERSION="2.319.1"
curl -O -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
tar xzf "actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
```

Use `osx-x64` instead of `osx-arm64` on Intel Macs.

## Step 2 — Register the runner

```bash
cd ~/actions-runner

./config.sh \
  --url https://github.com/LonghornSilicon/architecture \
  --token <TOKEN> \
  --labels self-hosted,<YOUR-LABEL> \
  --name <YOUR-RUNNER-NAME> \
  --unattended
```

Replace `<TOKEN>` with the value from GitHub. `<YOUR-LABEL>` is `longhorn-chamber-alan` / `-richard` / `-chaithu` per the table above. `<YOUR-RUNNER-NAME>` is anything descriptive (e.g., `alans-mbp`).

## Step 3 — Create your chamber config

```bash
mkdir -p ~/.longhorn

# Substitute YOUR values for CHAMBER_USER and CHAMBER_PATH
cat > ~/.longhorn/chamber.env <<'EOF'
CHAMBER_HOST=10.2.6.6
CHAMBER_PORT=222
CHAMBER_USER=schwartz
CHAMBER_PATH=/home/schwartz/architecture/
CHAMBER_INBOX=/home/schwartz/inbox/
CHAMBER_KEYCHAIN_SERVICE=longhorn-chamber
EOF

chmod 600 ~/.longhorn/chamber.env
```

`CHAMBER_PATH` is the canonical chamber-side repo location that `sync-promote` writes to. `CHAMBER_INBOX` is where bundles are deposited.

## Step 4 — Store your chamber password in Keychain

```bash
security add-generic-password -s longhorn-chamber -a "$USER" -w
```

Enter your chamber password at the prompt. (Don't pass it as `-w <value>` on the command line; that lands in shell history.)

## Step 5 — Smoke test the sync script

```bash
cd "/Users/$USER/Downloads/Longhorn Silicon/architecture"
bash .github/scripts/sync-chamber.sh
```

Expected output (final lines):
```
Bundle: /tmp/architecture-20260515T231540Z-abc1234.bundle (2.0M)
Target: schwartz@10.2.6.6:/home/schwartz/inbox/architecture-20260515T231540Z-abc1234.bundle
[... transfer log ...]

Uploaded: /home/schwartz/inbox/architecture-20260515T231540Z-abc1234.bundle

To promote in chamber (from an ETX shell):
    sync-promote
  or manually:
    cd ~/architecture && git fetch '/home/schwartz/inbox/architecture-20260515T231540Z-abc1234.bundle' main:refs/heads/main && git reset --hard main
```

First run pops a macOS Keychain access dialog. Click **Always Allow**.

## Step 6 — Bootstrap the chamber-side repo (ONE TIME)

The first bundle has to be cloned manually because there's no `~/architecture/` repo yet to `git fetch` into. After this one-time step, all future pushes are handled by `sync-promote`.

In an ETX shell on the chamber:

```bash
# 1. Make sure the inbox exists (it does after Step 5)
ls -la ~/inbox/

# 2. Pick the latest bundle (only one if this is the first push)
ls -t ~/inbox/architecture-*.bundle | head -1

# 3. Remove any pre-existing ~/architecture/ from earlier scp transfers
rm -rf ~/architecture

# 4. Clone from the bundle into ~/architecture
git clone "$(ls -t ~/inbox/architecture-*.bundle | head -1)" ~/architecture

# 5. Verify
cd ~/architecture
git log -1 --oneline
ls

# 6. The bundle path is baked into the clone's origin. Clear it so future
#    fetches use the path provided each time.
git remote remove origin
```

After Step 6 you have a real git repo at `~/architecture/` with full history.

## Step 7 — Install the `sync-promote` helper on the chamber

This is the chamber-side glue. Default chamber shell is tcsh; pick your variant.

**tcsh** (default on chamber). Append to `~/.cshrc`:

```tcsh
alias sync-promote 'set _b=`ls -t ~/inbox/architecture-*.bundle |& head -1`; if ("$_b" == "") then; echo "no bundles in ~/inbox/"; else; cd ~/architecture && git fetch "$_b" main && git reset --hard FETCH_HEAD && echo "promoted to `git log -1 --oneline` from $_b"; endif; unset _b'
```

**bash**. Append to `~/.bashrc`:

```bash
sync-promote() {
  local b
  b=$(ls -t ~/inbox/architecture-*.bundle 2>/dev/null | head -1)
  if [[ -z "$b" ]]; then echo "no bundles in ~/inbox/"; return 1; fi
  cd ~/architecture || return 1
  # Fetch into FETCH_HEAD (can't fetch directly into the checked-out branch),
  # then reset --hard to move main and update the working tree.
  git fetch "$b" main
  git reset --hard FETCH_HEAD
  echo "promoted to $(git log -1 --oneline) from $b"
}
```

Reload your shell or `source ~/.cshrc` / `source ~/.bashrc`. Test:

```bash
sync-promote
```

Should report something like `promoted to abc1234 (HEAD) latest commit subject from /home/schwartz/inbox/architecture-...bundle`.

Optional cleanup helper (removes bundles older than 7 days):

**tcsh**:
```tcsh
alias sync-prune 'find ~/inbox -maxdepth 1 -name "architecture-*.bundle" -mtime +7 -print -exec rm -f {} \;'
```

**bash**:
```bash
sync-prune() {
  find ~/inbox -maxdepth 1 -name 'architecture-*.bundle' -mtime +7 -print -exec rm -f {} +
}
```

## Step 8 — Start the runner as a background service

```bash
cd ~/actions-runner
./svc.sh install
./svc.sh start
./svc.sh status   # should show "active (running)"
```

The runner polls GitHub. Every push to `main` triggers a new bundle upload.

## Step 9 — End-to-end test

From your local clone:
```bash
echo "$(date)" >> /tmp/sync-test.txt
git add -A && git commit -m "test: chamber sync trigger"
git push origin main
```

Watch the run at `https://github.com/LonghornSilicon/architecture/actions`. Should complete in <1 min.

In ETX:
```bash
ls -t ~/inbox/architecture-*.bundle | head -1   # see the new bundle
sync-promote                                     # apply it
git log -1                                       # confirm chamber is now at the new commit
```

## Mirror semantics (read this once)

After `sync-promote`, `~/architecture/` exactly matches what was on `main` at the time of the push that produced the latest bundle. `git reset --hard` is destructive to local changes inside `~/architecture/`.

- **Do not modify files inside `~/architecture/` on the chamber.** They get overwritten on the next promote.
- **Chamber-side scratch work** (sim outputs, intermediate Tcl, `xrun.log`, build artifacts) **must live OUTSIDE `~/architecture/`**. Recommended: `~/chamber_work/` (create yourself, never touched by sync).
- Bundles in `~/inbox/` are append-only. Run `sync-prune` periodically.

## Mac sleep / availability

If your Mac sleeps, queued GH Actions jobs wait until it wakes.

```bash
# While runner is active, keep Mac awake
caffeinate -di &

# Or persistent (no sleep on AC power)
sudo pmset -c sleep 0
```

For Phase 1 (Alan only), neither is strictly required.

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Workflow shows "queued" forever | No runner online with matching label | `cd ~/actions-runner && ./svc.sh start` |
| `lftp: command not found` | Not installed | `brew install lftp` |
| `sshpass: command not found` | Not installed | `brew install hudochenkov/sshpass/sshpass` |
| `git: command not found` (CI) | Should never happen on macOS runner | Install Xcode CLT: `xcode-select --install` |
| Keychain dialog every run | "Always Allow" was not selected | Re-run Step 5, click "Always Allow" |
| `dest open ... Permission denied` on bundle upload | Bundle filename collided (same timestamp + same SHA, very rare) | Wait 1s and retry, or `rm` the offending bundle in ETX |
| `Connection timed out` | Not on UT Austin VPN, or chamber is down | Confirm VPN, try `sshpass -e sftp -P 222 ... schwartz@10.2.6.6` manually |
| `sync-promote: no bundles in ~/inbox/` | Workflow never landed a bundle (or already cleaned) | Push a commit to main, wait, retry |
| `git fetch` fails with "couldn't find remote ref main" | Bundle was built from a checkout that doesn't have main | Probably shallow CI checkout. Confirm `fetch-depth: 0` in workflow. |
| `git fetch` fails with "fatal: not a git repository" | Bootstrap (Step 6) wasn't done | Do Step 6, then retry |

## Phase B: if Cadence lifts the SFTP write restriction

If a support case enables normal SFTP write (overwrite + delete) for your account, you could switch back to a true tree-mirror with `rsync` or `lftp mirror --delete`. The bundle approach has its own advantages even with full SFTP write (incremental object transfer via git's dedup, real git repo on chamber), so probably not worth switching back.

## Updating the matrix when a teammate onboards

Once Richard or Chaithu has completed Steps 1 through 8, uncomment their line in `.github/workflows/sync-chamber.yml`:

```yaml
matrix:
  runner_label:
    - longhorn-chamber-alan
    - longhorn-chamber-richard       # uncommented after Richard onboards
    # - longhorn-chamber-chaithu
```

Push the change. Their next push triggers parallel syncs for all listed teammates.
