# Deployed Traccar — Source Provenance & Operations

This repo (**TraccarOps**) holds **deployment/operations only**. The authoritative
Traccar **application source** lives in our private fork:

- Private fork (canonical source): `git@github-traccar:malnahhas-star/traccar.git`  → git remote `origin`
- Public upstream (fetch/merge future releases only, never our deploy source): `github.com/traccar/traccar` → git remote `upstream`
- Local working copy on ops box: `/home/ubuntu/Development/Projects/Traccar`

## Currently deployed build

```text
Source commit:          dc48939   (branch: cvx/production, tag: v6.13.3-cvx.1)
Traccar version:        6.13.3
CacheManager.class SHA256: eb63e16fc1321a8b2b3a26d8e9a2996becccebb47391da52727d0762bbfa887e
PositionUtil.class SHA256: b757f7bebf358142efafd35491d268039e619f87b481541b201e997f9c105eaa
Deployed:               2026-09-18, all 8 tracker nodes (T01–T07, T09)
```

Reproducibility: a clean build (`./gradlew --no-daemon clean compileJava jar`) of
commit `dc48939` produces those two class files **byte-identical** (SHA256 verified)
to the classes running in production.

## What changed (the two-stage last-position-by-id lookup)

`CacheManager.addDevice()` loaded a device's last position by `(deviceId, id)` with
no time bound, so TimescaleDB scanned + decompressed **every** `tc_positions` chunk
on each fresh cache entry (~70M calls, ~24% of all DB time) → slow reports / stuck
history. Commit `dc48939` routes that read through the new
`PositionUtil.getLastPositionById()`:

- **Fast path:** `deviceId=? AND id=? AND fixTime >= now()-database.positionPeriod` → chunk-pruned.
- **Fallback:** unbounded `deviceId=? AND id=?`, run **only** when the fast path finds
  nothing (device offline longer than `positionPeriod`) → exact legacy behaviour preserved.

`database.positionPeriod` = **604800 (7 days)** in each node's `traccar.xml`. Do NOT change it.

## Deployment mechanism (override classes)

Traccar `ExecStart` uses `-cp override:tracker-server.jar:lib/*`, so classes in
`/opt/traccar/override/` load **before** the jar. The two changed classes are deployed
there (built from `dc48939`), not by replacing the jar:

```
/opt/traccar/override/org/traccar/session/cache/CacheManager.class   (eb63e16f…)
/opt/traccar/override/org/traccar/helper/model/PositionUtil.class     (b757f7be…)
```

Both classes MUST be deployed together (CacheManager calls the new
`PositionUtil.getLastPositionById`; the jar's PositionUtil does not have it →
`NoSuchMethodError` otherwise).

Nodes & private IPs (SSH via T01 jump host, per-node `T0x.key`):
T02 20.0.4.197 · T03 20.0.4.159 · T04 20.0.4.231 · T05 20.0.4.2 · T06 20.0.4.65 ·
T07 20.0.4.126 · T09 20.0.4.154 · T01 145.241.108.6 (jump host).
T08 = admin console, not a tracker.

## Build the deployed classes from source

```bash
git clone git@github-traccar:malnahhas-star/traccar.git traccar && cd traccar
git checkout v6.13.3-cvx.1          # == commit dc48939
./gradlew --no-daemon clean compileJava jar
# extract + verify the two override classes:
mkdir -p /tmp/x && cd /tmp/x
unzip -oq ../traccar/target/tracker-server.jar \
  org/traccar/session/cache/CacheManager.class \
  org/traccar/helper/model/PositionUtil.class
sha256sum org/traccar/session/cache/CacheManager.class   # expect eb63e16f…
sha256sum org/traccar/helper/model/PositionUtil.class     # expect b757f7be…
```

## Health check (post-deploy)

Each node logs a rate-limited (once/60s) line at WARN when the lookup is exercised:

```
position_lookup_by_id bounded_attempts=… bounded_hits=… bounded_misses=… fallback_exec=… fallback_hits=…
```

Healthy = `active` service, expected device ports up (94), zero
`NoSuchMethod/NoClassDef/ClassNotFound/SEVERE`, and bounded_hits ≫ fallback_exec.

## Rollback (per node, simple)

```bash
# Standard nodes (no prior override before this deploy) — remove both classes:
ssh T0x 'sudo rm -f \
  /opt/traccar/override/org/traccar/session/cache/CacheManager.class \
  /opt/traccar/override/org/traccar/helper/model/PositionUtil.class && \
  sudo systemctl restart traccar'

# T01 special case (had a prior Sep-1 30-day bounded-only override, backed up first):
ssh T01 'sudo cp \
  /opt/traccar/override/org/traccar/session/cache/CacheManager.class.bak-oldoverride-20260918-133256 \
  /opt/traccar/override/org/traccar/session/cache/CacheManager.class && \
  sudo rm -f /opt/traccar/override/org/traccar/helper/model/PositionUtil.class && \
  sudo systemctl restart traccar'
```

## Branch model

- `cvx/production` — **production branch**. Always points at the exact commit deployed
  to the fleet. Deployments build from here (or from a release tag on it).
- `v6.13.3-cvx.<n>` — release tag per deployed build (current: `v6.13.3-cvx.1`).
- Feature branches (e.g. `cvx/positions-byid-twostage`) merge into `cvx/production`.
- Adopting a new Traccar release: `git fetch upstream`, merge the upstream tag into a
  branch off `cvx/production`, rebuild, re-test, then fast-forward `cvx/production`.

## Deployment source-of-truth (CI/CD)

Override classes are **never hand-maintained**. They are produced by CI in the private
fork (`malnahhas-star/traccar`) and only then staged to nodes:

```text
Git tag (v*-cvx.*)
  ↓
GitHub Actions  (.github/workflows/override-bundle.yml)
  ↓
tested build    (./gradlew compileJava checkstyleMain test)   ← JDK 17.0.20 (see below)
  ↓
versioned override artifact   (traccar-overrides-<version>.tar.gz)
  ↓
SHA256 verification           (scripts/known-good/<version>.sha256; build fails on mismatch)
  ↓
staged deployment             (operator step — NOT done by CI)
```

- Pipeline lives in the fork: workflow `.github/workflows/override-bundle.yml`,
  builder `scripts/build-override-bundle.sh` (same script runs locally and in CI).
- Triggers: PRs targeting `cvx/production`, pushes to `cvx/production`, and tags
  matching `v*-cvx.*`. Tag builds also publish a GitHub Release with the `.tar.gz`
  + `SHA256SUMS` (using the built-in `GITHUB_TOKEN`).
- Bundle contents: `org/traccar/session/cache/CacheManager.class`,
  `org/traccar/helper/model/PositionUtil.class`, `SHA256SUMS`, `SOURCE_COMMIT`,
  `VERSION`, `TRACCAR_VERSION`, `BUILD_INFO.txt`.
- **Known-good gate:** each release version pins its expected class hashes in
  `scripts/known-good/<version>.sha256`. `v6.13.3-cvx.1` pins the currently deployed
  `eb63e16f…` / `b757f7be…`; the build fails if it does not reproduce them.

### Build JDK — must be 17.0.20 (not 21)

The deployed override classes are **Java 17 bytecode (major 61)**, compiled with
**JDK 17.0.20** (`build.gradle` sets source/target = 17). The tracker nodes run
Java 21 at *runtime*, which loads Java-17 classes fine — but to reproduce the exact
`eb63e16f…` / `b757f7be…` bytes the build MUST use JDK 17.0.20. CI pins Temurin
17.0.20 for this reason. Moving the build to Java 21 would change the hashes and
would require re-baselining `scripts/known-good/` and re-deploying the new classes.

### Deploying a CI-produced bundle (manual, when authorized)

```bash
# On the ops box, per node (example T0x), from a downloaded/verified bundle:
tar xzf traccar-overrides-<version>.tar.gz
( cd traccar-overrides && sha256sum -c SHA256SUMS )   # must pass
scp traccar-overrides/org/traccar/session/cache/CacheManager.class  T0x:/tmp/
scp traccar-overrides/org/traccar/helper/model/PositionUtil.class   T0x:/tmp/
# then place under /opt/traccar/override/... (both together) + restart traccar.
```

## Follow-ups (longer term)

- CI produces the bundle; wire a **separate, gated** deploy step (still one node at a
  time, health-checked) so nodes pull the verified artifact instead of manual scp.
- Migrate the remaining custom override source (`traccar-handlers/DistanceHandler.java`)
  into the private fork so ALL Java lives in one source repo; keep only its build/deploy
  metadata here, and add it to the override bundle.
