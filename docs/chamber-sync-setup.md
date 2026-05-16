# Chamber Sync Setup

One-time setup guide for getting `git push origin main` to automatically mirror this repo into your Cadence chamber home.

## What you'll have when you're done

- Every push to `main` on `github.com/LonghornSilicon/architecture` will, within ~10 seconds, drop a fresh git bundle into `~/inbox/` on your chamber account.
- A single command in your chamber ETX shell (`sync-promote`) applies the bundle to `~/architecture/`, bringing it to whatever's on `main`.
- The whole thing runs from a self-hosted GitHub Actions runner on your own Mac — no cloud servers, no shared infra.

## Prerequisites

| Thing | Where | Why |
|---|---|---|
| Mac (macOS 12+) | Your laptop | Hosts the GitHub Actions runner |
| Cadence chamber account | Provisioned by Cadence | `schwartz` for Alan, `richuang` for Richard, `tchaithu` for Chaithu |
| Chamber password | Personal | Used by the runner to SFTP your bundles up |
| GitHub admin on LonghornSilicon/architecture | Org | Needed to fetch a runner registration token |
| UT Austin VPN connectivity from your Mac | Required | Chamber is on a private network |

## Why this setup exists

The chamber blocks two operations we'd normally use for sync:
- SSH `exec` is blocked, killing rsync over SSH and any "run a remote command" approach.
- SFTP allows file creates but rejects overwrite and delete on existing files.

So we use **git bundles**: each push produces a single bundle file with a unique name (no overwrite needed), the SFTP upload always succeeds, and a `git fetch` + `git reset --hard` from inside an ETX shell applies it. Git's object model handles deduplication so chamber disk grows only by the diff between commits, even though bundles contain full history.

## Your label and paths

| Teammate | Runner label | CHAMBER_USER | CHAMBER_PATH |
|---|---|---|---|
| Alan | `longhorn-chamber-alan` | `schwartz` | `/home/schwartz/architecture/` |
| Richard | `longhorn-chamber-richard` | `richuang` | `/home/richuang/architecture/` |
| Chaithu | `longhorn-chamber-chaithu` | `tchaithu` | `/home/tchaithu/architecture/` |

These values plug into the steps below.

---

## Setup steps

Run these on your Mac unless marked **[CHAMBER]**.

### Step 1 — Install tools

```bash
# Homebrew (skip if installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Sync engine and password helper
brew install hudochenkov/sshpass/sshpass
brew install lftp
brew install gh

# Verify git is recent enough
git --version    # any 2.x is fine
```

### Step 2 — Write your runner config

This file holds your chamber connection details and password. It lives outside the repo (`~/.longhorn/chamber.env`) and is mode 0600 so only your user can read it.

```bash
mkdir -p ~/.longhorn

cat > ~/.longhorn/chamber.env <<'EOF'
CHAMBER_HOST=10.2.6.6
CHAMBER_PORT=222
CHAMBER_USER=<your-chamber-user>
CHAMBER_PATH=/home/<your-chamber-user>/architecture/
CHAMBER_INBOX=/home/<your-chamber-user>/inbox/
CHAMBER_PASSWORD=<your-chamber-password>
EOF

chmod 600 ~/.longhorn/chamber.env
```

Substitute the values from the table above plus your password. `chamber.env` is gitignored — it will never end up in the repo.

### Step 3 — Smoke-test the sync script standalone

Before involving GitHub Actions, run the script directly to confirm bundle creation and upload work from your Mac.

```bash
cd "/path/to/your/architecture/clone"
bash .github/scripts/sync-chamber.sh
```

You should see something like:
```
Bundling main (HEAD=abcd123)...
Bundle: /var/folders/.../architecture-20260516T001620Z-abcd123.bundle (500K)
Target: <your-user>@10.2.6.6:/home/<your-user>/inbox/architecture-20260516T001620Z-abcd123.bundle

Uploaded: /home/<your-user>/inbox/architecture-20260516T001620Z-abcd123.bundle

To promote in chamber (from an ETX shell):
    sync-promote
```

If you see `Uploaded:`, the upload half works.

### Step 4 — **[CHAMBER]** Bootstrap your chamber-side repo (one time)

Open an ETX session on the chamber and paste:

```tcsh
cd ~
rm -rf architecture     # clean any prior state from manual scp/lftp experiments
git clone /home/<your-chamber-user>/inbox/architecture-*.bundle ~/architecture
cd ~/architecture
git remote remove origin
git log -1 --oneline    # should show the latest commit on main
```

After this, you have a real git repo at `~/architecture/` that future syncs will update incrementally.

### Step 5 — **[CHAMBER]** Install the `sync-promote` helper

This is what you'll run in ETX whenever you want your chamber tree to catch up to `main`. It lives at `~/bin/sync-promote` and just does `git fetch` from the newest bundle + `git reset --hard`.

Easiest way to get the script onto the chamber: have someone with a working Mac-side runner SFTP it to you (see "Helping a new teammate" below), or paste it manually if your ETX terminal supports paste:

```bash
#!/bin/bash
set -e
b=$(ls -t ~/inbox/architecture-*.bundle 2>/dev/null | head -1)
if [ -z "$b" ]; then
  echo "no bundles in ~/inbox/"
  exit 1
fi
cd ~/architecture
git fetch "$b" main
git reset --hard FETCH_HEAD
echo "promoted to $(git log -1 --oneline) from $b"
```

Save as `~/bin/sync-promote`, then `chmod 755 ~/bin/sync-promote`.

Test it (should report "Already up to date" since you just cloned):
```bash
~/bin/sync-promote
```

### Step 6 — Install the GitHub Actions runner

Get a registration token: visit `https://github.com/LonghornSilicon/architecture/settings/actions/runners/new` in a browser, scroll to find the `--token <TOKEN>` value on that page, copy it. (Token expires in 1 hour, so move quickly.)

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner

# Get the current version from https://github.com/actions/runner/releases
RUNNER_VERSION="2.334.0"
curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz
tar xzf actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz
```

Use `osx-x64` instead of `osx-arm64` on Intel Macs.

### Step 7 — Register your runner with the right label

```bash
cd ~/actions-runner
./config.sh \
  --url https://github.com/LonghornSilicon/architecture \
  --token <PASTE-TOKEN-HERE> \
  --labels self-hosted,<your-runner-label> \
  --name <your-mac-name> \
  --unattended
```

`<your-runner-label>` is `longhorn-chamber-alan` / `-richard` / `-chaithu`. `<your-mac-name>` is anything descriptive (e.g., `alans-mbp`).

### Step 8 — Install as a background service

```bash
cd ~/actions-runner
./svc.sh install      # registers a macOS LaunchAgent under ~/Library/LaunchAgents/
./svc.sh start        # starts the runner polling GitHub
./svc.sh status       # confirm "active (running)"
```

This installs the runner as a user-level LaunchAgent. No `sudo` needed. The runner auto-starts on login. It will keep running in the background as long as your Mac is awake.

### Step 9 — Wire up the workflow matrix

If your label is already listed in `.github/workflows/sync-chamber.yml`, skip this. Otherwise, open a PR that uncomments your line:

```yaml
matrix:
  runner_label:
    - longhorn-chamber-alan
    - longhorn-chamber-richard       # uncomment when Richard onboards
    # - longhorn-chamber-chaithu
```

Merge to main. Your next push will trigger sync for all listed teammates in parallel.

### Step 10 — End-to-end test

From your local clone:
```bash
echo "$(date)" >> /tmp/sync-test.txt
git add -A && git commit -m "test: chamber sync trigger"
git push origin main
```

Watch the run at `https://github.com/LonghornSilicon/architecture/actions`. Should complete in <30s.

In ETX:
```bash
ls -t ~/inbox/architecture-*.bundle | head -1      # see the new bundle
~/bin/sync-promote                                  # apply it
git log -1                                          # confirm chamber is now at the new commit
```

If you see the test commit on the chamber, you're done.

---

## After it's working

### Mirror semantics — important

`sync-promote` does `git reset --hard`, which is destructive to anything inside `~/architecture/` on the chamber. **Do not edit files in `~/architecture/` directly on the chamber.** Use it as a read-only point-in-time snapshot of `main`.

Chamber-side scratch work (sim outputs, intermediate Tcl, `xrun.log`, build artifacts) **must live OUTSIDE `~/architecture/`**. Recommended: `~/chamber_work/` (you create this yourself).

### Keeping your Mac available

The runner only picks up jobs while your Mac is awake.

```bash
# Keep awake while runner is active
caffeinate -di &

# Or persistent (never sleep on AC power)
sudo pmset -c sleep 0
```

If your Mac sleeps mid-day, pushes queue. They run when it wakes. No data is lost.

### Cleaning up old bundles

Bundles accumulate in `~/inbox/`. They're small (~500 KB each) but worth pruning occasionally. From ETX:

```bash
find ~/inbox -name 'architecture-*.bundle' -mtime +7 -delete
```

You can alias this as `sync-prune` if you do it often.

### Rotating your chamber password

If you change your chamber password (`passwd` from ETX), update `CHAMBER_PASSWORD=` in `~/.longhorn/chamber.env` on your Mac. No code change, no restart.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Workflow shows "Queued" forever | Your runner isn't online | `cd ~/actions-runner && ./svc.sh start` |
| `lftp: command not found` | Not installed | `brew install lftp` |
| `sshpass: command not found` | Not installed | `brew install hudochenkov/sshpass/sshpass` |
| `git: command not found` | Should never happen on macOS | `xcode-select --install` |
| `No password source` | `CHAMBER_PASSWORD=` missing from chamber.env | Add it: `echo "CHAMBER_PASSWORD=<pw>" >> ~/.longhorn/chamber.env` |
| `dest open ... Permission denied` on bundle upload | Filename collision (same SHA + same timestamp second) | Wait 1s and retry, or `rm` the offending bundle in ETX |
| `Connection timed out` | Not on UT Austin VPN, or chamber is down | Confirm VPN, try `sshpass -e sftp -P 222 ... <user>@10.2.6.6` manually |
| `sync-promote: no bundles` | Workflow never landed a bundle, or all pruned | Push a commit to main, wait, retry |
| `git fetch` fails with "couldn't find remote ref main" | Bundle was built from a shallow checkout | Confirm `fetch-depth: 0` in workflow (it is, by default in our setup) |
| `git fetch` fails with "not a git repository" | Step 4 (bootstrap) wasn't done | Do Step 4 |
| Keychain entry not found (when using Method B) | LaunchAgent can't reach Keychain | Switch to Method A (CHAMBER_PASSWORD in chamber.env) |

---

## Helping a new teammate set up

When the next teammate (Richard, Chaithu, etc.) starts setup, they need:

1. The doc you're reading.
2. Their personal chamber credentials (CHAMBER_USER + password from Cadence).
3. The `sync-promote` script on their chamber. If they can't paste into their ETX, you can SFTP it from your Mac to their inbox:
   ```bash
   sshpass -e sftp -P 222 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
     <their-user>@10.2.6.6 <<EOF
   put /path/to/sync-promote bin/sync-promote
   chmod 755 bin/sync-promote
   bye
   EOF
   ```
   (They'd need to provide their password via Keychain or `SSHPASS` env var first.)

After they finish Steps 1-8, open a PR uncommenting their line in `.github/workflows/sync-chamber.yml`. Once merged, every push syncs to all listed teammates in parallel.

---

## Reference: How it works under the hood

**The runner.** GitHub Actions hosts the workflow definition; the actual job execution happens on a self-hosted runner you registered. The runner is a small .NET process (`Runner.Listener`) installed at `~/actions-runner/` and managed by a macOS LaunchAgent at `~/Library/LaunchAgents/actions.runner.<repo>.<name>.plist`. It long-polls `api.github.com` waiting for jobs labeled with its labels. When a push to `main` happens, GitHub queues the workflow's `sync` job; your runner's label match means it claims the job, checks out the repo with full history, runs `bash .github/scripts/sync-chamber.sh`, and reports the result back.

**The bundle upload.** The script does `git bundle create main HEAD` to produce a single binary file containing the full history of main. It then `lftp put`s that file to `<your-chamber-user>@10.2.6.6:~/inbox/architecture-<timestamp>-<sha>.bundle` over SFTP port 222. The unique filename per push sidesteps the chamber's SFTP write-once policy.

**The promote.** On chamber, `~/bin/sync-promote` finds the newest bundle, runs `git fetch <bundle> main` (lands in `FETCH_HEAD`), and `git reset --hard FETCH_HEAD` to advance `main` and update the working tree. Git's object store dedups: even though every bundle has full history, only new objects get written to `~/architecture/.git/objects/`.

**The auth.** Two supported paths:
- **Method A (used by the runner):** `CHAMBER_PASSWORD=` in `~/.longhorn/chamber.env`. The script exports it to `SSHPASS` for sshpass-based password auth.
- **Method B (for interactive local runs):** macOS Keychain. Script falls back to this when `CHAMBER_PASSWORD` is unset.

The script auto-detects which is available. Don't put `CHAMBER_PASSWORD` in the repo — `.longhorn/` is gitignored.

**Future: SSH key auth.** If Cadence installs your public key in `~/.ssh/authorized_keys` on the chamber, the script supports key auth via `CHAMBER_SSH_KEY=` in chamber.env. Eliminates the need to store passwords anywhere. Worth filing a Cadence support case for once setup is stable.
