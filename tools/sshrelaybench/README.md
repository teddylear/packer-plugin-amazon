# SSH Relay Benchmark Matrix

This directory contains a local harness for comparing the SSH communicator
behavior that shipped in plugin `v1.8.0` vs `v1.8.1` dependency profiles.

The harness exercises the SDK path used by this plugin:

- `communicator.StepConnectSSH`
- `packersdk.RemoteCmd.RunWithUi`

It is meant to turn the issue reports in:

- `#678` stdout relay slowdown / `exit status: 123`
- `#676` high CPU / `EOF` / `123`

into concrete, ranked scenarios.

## Profiles

- `go.sshbench.v180.mod`: plugin `v1.8.0`-equivalent SSH dependency profile
- `go.sshbench.v181.mod`: plugin `v1.8.1`-equivalent SSH dependency profile

All commands below should be run with:

```bash
GOPATH="/var/folders/p9/xthrx4zs2y11qbl1k6kznk2w0000gn/T/opencode/gopath"
```

## Ranked Matrix

### Tier 1: Easiest Local Checks

These are the fastest sanity checks and should be run first.

#### 1. Chatty stdout, localhost in-process SSH

Matches issue signal:

- lots of stdout
- host-side line relay timing

Command:

```bash
GOPATH="$GOPATH" \
go test -mod=mod -modfile=go.sshbench.v180.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench

GOPATH="$GOPATH" \
go test -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench
```

Current status:

- supported by harness
- already run
- did not reproduce the issue

#### 2. Chatty stdout, Docker OpenSSH

Matches issue signal:

- real OpenSSH server
- lots of stdout

Command:

```bash
GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
go test -mod=mod -modfile=go.sshbench.v180.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench

GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
go test -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench
```

Current status:

- supported by harness
- already run
- did not reproduce the issue

### Tier 2: Closest Local Approximation To The Reports

These scenarios add WAN-like impairment and are the best current local proxy
for the GitHub-runner-to-EC2 reports.

#### 3. Chatty stdout, Docker OpenSSH, latency + jitter

Matches issue signal:

- cross-network path sensitivity
- lots of stdout
- host-side slowdown suspicion

Command:

```bash
GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v180.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench

GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench
```

Current status:

- supported by harness
- already run
- slower than the no-latency case, but still no dramatic regression

### Tier 3: Hypothesis Splitters

These isolate branches from the issue discussion.

#### 4. `TCP_NODELAY` branch

Purpose:

- test whether packetization / Nagle behavior explains the slowdown

Commands:

```bash
GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
SSHRELAYBENCH_TCP_NODELAY=false \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench

GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
SSHRELAYBENCH_TCP_NODELAY=true \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench
```

Current status:

- supported by harness
- already run
- no dramatic effect observed

#### 5. Forced old KEX branch

Purpose:

- test whether old-vs-new key exchange selection is the trigger

Command:

```bash
GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
SSHRELAYBENCH_FORCE_KEX=curve25519-sha256@libssh.org \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench
```

Current status:

- supported by harness
- already run
- no dramatic effect observed

#### 6. Forced cipher branch

Purpose:

- test whether cipher selection matters more than KEX

Commands:

```bash
GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
SSHRELAYBENCH_FORCE_CIPHERS=chacha20-poly1305@openssh.com \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench

GOPATH="$GOPATH" \
SSHRELAYBENCH_TARGET=docker \
SSHRELAYBENCH_PROXY=latency \
SSHRELAYBENCH_LATENCY=20ms \
SSHRELAYBENCH_JITTER=10ms \
SSHRELAYBENCH_LINES=100 \
SSHRELAYBENCH_TIMEOUT=20s \
SSHRELAYBENCH_FORCE_CIPHERS=aes128-ctr \
go test -timeout 60s -mod=mod -modfile=go.sshbench.v181.mod -run TestRelayMetrics -count=1 -v ./tools/sshrelaybench
```

Current status:

- supported by harness
- not yet run

## Scenarios From The Issues That The Harness Can Approximate

### Supported well enough to learn something locally

- shell loop producing `1000+` lines of stdout
- real OpenSSH server
- increased latency / jitter
- host-side line timing measurement
- KEX/cipher override experiments
- `TCP_NODELAY` toggle on proxy sockets

## Scenarios From The Issues That Are Not Fully Modeled Yet

### Not currently reproduced by this harness

- `ssh_interface = "session_manager"`
- SSM port-forward behavior
- `Error accepting response stream <id>: timeout waiting for accept`
- real GitHub-runner-to-EC2 path
- tiny CPU host pressure on the runner/host
- package-manager output shapes like `yum update` or `apt upgrade`
- Ansible cleanup execs such as final `rm` temp-script removal

These need either:

- a real AWS integration test path, or
- a more complex local multiplexer / backpressure model than we have now

## Suggested Next Test Order

1. Run the forced cipher branch.
2. If still flat, try stronger impairment:
   - higher latency
   - bandwidth cap
   - bursty delay
3. If still flat, move to remote AWS validation:
   - direct SSH
   - then `session_manager`

## Reading The Results

Useful fields from `TestRelayMetrics`:

- `connect_duration_ms`
- `run_duration_ms`
- `first_line_ms`
- `median_gap_ms`
- `p95_gap_ms`
- `lines`
- `exit_status`

The issue reports would look like:

- very large `run_duration_ms`
- very large `first_line_ms` or `p95_gap_ms`
- possibly truncated `lines`
- possibly non-zero `exit_status`

The current local runs do not show that signature.
