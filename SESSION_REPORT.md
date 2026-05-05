# Session report: nullq-qns scaffold

Date: 2026-05-04

## Goal

Ship a standalone Docker image that publishes nullq's `qns-endpoint` for
the official QUIC interop runner
([marten-seemann/quic-interop-runner](https://github.com/marten-seemann/quic-interop-runner))
on top of the upstream
`martenseemann/quic-network-simulator-endpoint:latest` base. Layout
modeled on [`nginx/nginx-quic-qns`](https://github.com/nginx/nginx-quic-qns):
a small repo that exists alongside the implementation rather than inside
it, with its own Dockerfile, entrypoint, Makefile, README, and a CI job
that nightly-rebuilds against the implementation's tip.

## Result

New sibling project at `~/prj/ai-workspace/nullq-qns/`:

```
nullq-qns/
├── .github/workflows/docker-publish.yml
├── .gitignore
├── Dockerfile
├── Makefile
├── README
└── run_endpoint.sh
```

## Approach

- nullq already had `interop/qns_endpoint.zig` (the QNS endpoint binary,
  built via `zig build qns-endpoint`) and an internal
  `interop/qns/Dockerfile` driven by `nullq-external-interop`. That one
  uses `COPY` from a sibling-on-disk build context — fine for local dev
  under `zig build external-interop`, but not what the upstream runner
  pulls.
- nullq-qns instead clones `nullstyle/nullq` and `nullstyle/boringssl-zig`
  from GitHub at configurable refs (`NULLQ_REF`, `BORINGSSL_ZIG_REF`,
  default `main`) and places them as siblings under `/src/` so nullq's
  path-dep `../boringssl-zig` resolves naturally. Image is reproducible
  from the Dockerfile + URL alone.
- Two images coexist on purpose: nullq-qns is canonical-published;
  nullq's internal one stays as the developer-loop convenience.
- Runtime image carries only `/qns-endpoint` (22 MiB ELF) and
  `/run_endpoint.sh`. The Zig toolchain and source trees from the
  builder stage are discarded.

## Verification

| Check | Result |
| --- | --- |
| `bash -n run_endpoint.sh` | OK |
| `docker build --pull --target build` (cold cache) | exit 0, ~75 s on linux/arm64 |
| `docker build` full image (with cache) | exit 0; `/qns-endpoint` and `/run_endpoint.sh` present |
| `/qns-endpoint` invoked with no args | prints usage, exits cleanly |
| `TESTCASE=versionnegotiation` (explicitly unsupported) | exit 127 with diagnostic |
| `TESTCASE=nonsense` (unknown) | exit 127 with diagnostic |
| `apt-get` package set on `martenseemann/...` base | builds with just `ca-certificates curl xz-utils git` (no cmake/ninja/clang/python/perl needed for the Zig-native paths) |

## Findings

### Upstream nullq build gotcha

`zig build qns-endpoint` in `nullq/build.zig` only **compiles** the
endpoint — it does not install it. The relevant lines:

```zig
b.installArtifact(qns_exe);
...
const qns_step = b.step("qns-endpoint", "Build the QUIC interop-runner endpoint");
qns_step.dependOn(&qns_exe.step);
```

The named `qns-endpoint` step depends on the Compile step, not on the
InstallArtifact step that `b.installArtifact` registers under the default
`install` step. Effect: `zig-out/bin/qns-endpoint` is never populated; the
binary instead lives at `.zig-cache/o/<content-hash>/qns-endpoint`, which
is not a stable Docker `COPY` source.

The Dockerfile works around this by invoking `zig build install` (the
default step), which compiles and installs every `b.installArtifact()`
entry — both `qns-endpoint` and `nullq-external-interop`. The extra
artifact lives only in the builder stage; the runtime image is unchanged.

**Recommended upstream fix** in `nullq/build.zig`:

```zig
qns_step.dependOn(&b.addInstallArtifact(qns_exe, .{}).step);
```

After that lands, the Dockerfile can switch back to
`zig build qns-endpoint -Doptimize=ReleaseSafe` for a more selective
build that doesn't also produce `nullq-external-interop`.

### TESTCASE allowlist

`run_endpoint.sh` mirrors the allowlist already in
`nullq/interop/qns/run_endpoint.sh`:

- supported: handshake, transfer, longrtt, chacha20, multiplexing, retry,
  resumption, zerortt, keyupdate, blackhole, handshakeloss, transferloss,
  handshakecorruption, transfercorruption (plus empty/default).
- explicitly unsupported (exit 127): versionnegotiation, http3,
  multiconnect, connectionmigration, amplificationlimit, crosstraffic,
  goodput, v2, ecn.
- unknown name: also exit 127.

These are aspirational-on-the-passing-side; per `INTEROP_STATUS.md` the
real runner gate has not yet been driven end-to-end in a Wireshark/Docker
environment. First real runs may surface fixes.

### CI workflow

Adapted from nginx's: skopeo-inspects the registry's `commit_id` label,
compares it to the latest `nullstyle/nullq` SHA (via GitHub's commits
API), and rebuilds + pushes only when those differ. Pushes go to
`ghcr.io/nullstyle/nullq-qns`. Triggers: nightly cron, push to `main`,
PR (build-only, no push), and `workflow_dispatch`.

## Open follow-ups

1. **Repo not yet pushed.** `git init` + create
   `github.com/nullstyle/nullq-qns` + push. The workflow then activates.
2. **ghcr.io visibility.** Package needs to be made public (or the runner
   needs a pull token) before the official runner can use it
   without auth.
3. **Multi-arch.** Workflow currently builds `linux/amd64` only.
   Enabling `linux/arm64` doubles cold-build time (no QEMU emulation
   speedup for Zig + BoringSSL) but lets ARM hosts pull native.
4. **Implementations registration.** Once published, the image needs an
   entry in `quic-interop-runner`'s `implementations.json` PR before
   `interop.seemann.io` will exercise it.
5. **Resolved locally: trace plumbing.** `run_endpoint.sh` now forwards
   `SSLKEYLOGFILE` and `QLOGDIR`; `qns_endpoint.zig` accepts them in
   both roles. Local loopback smoke verified key log lines and nullq
   qlog-style JSONL files.
6. **Resolved locally: upstream nullq build step.** `zig build
   qns-endpoint` now depends on the install artifact, so
   `zig-out/bin/qns-endpoint` is populated directly. The Dockerfile is
   back to the selective `zig build qns-endpoint -Doptimize=ReleaseSafe`
   invocation.

## Follow-up: local-source validation path

The repo now includes `Dockerfile.local` and Make targets that build the
QNS image from sibling workspace checkouts instead of cloning GitHub.
That keeps the published `Dockerfile` reproducible while allowing
pre-push validation of the exact `../nullq` and `../boringssl-zig`
worktree contents:

```
make build-local
make interop
make interop-features
```

`make interop` uses the `../nullq` Zig wrapper to create a throwaway
official-runner overlay and substitute `nullq-qns:local` as the nullq
implementation image. Defaults assume `../quic-interop-runner` is
present.

Verified with the current workspace:

```
make build-local
make interop
make interop-features
```

Results:

```
quic-go, ngtcp2, quiche: ✓(H,DC)
quic-go: ✓(H,DC,C20,S,R,Z,M)
```

The quic-go feature run still prints the upstream runner warning
`At least one QUIC packet could not be decrypted`, matching the internal
nullq image run. The matrix result is green.
