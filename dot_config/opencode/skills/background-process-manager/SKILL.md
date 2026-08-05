---
name: background-process-manager
description: Manage long-running and background processes safely from an agent shell. Use when starting, restarting, stopping, monitoring, or cleaning up development servers, watchers, build processes, test runners, local services, or any command that must outlive a shell-tool invocation. Prevent shell-tool hangs caused by broad process matching, inherited file descriptors, interactive prompts, or incomplete cleanup.
---

# Background Process Manager

Manage background processes so the shell invocation returns promptly, the service is verifiably ready, logs are retained, and cleanup targets only the intended process.

## Core rules

1. Never use `pkill -f`, `pgrep -f`, or `killall` with text that also appears in the submitted shell command. An agent shell wrapper can contain the entire command string; broad full-command-line matching can kill the wrapper itself and leave the tool waiting until timeout.
2. Prefer, in order:
   - a service manager (`systemctl --user`, Docker Compose, supervisor, project-native stop command),
   - a validated PID file,
   - the PID listening on a known port,
   - exact executable-name matching with `pkill -x` only when unambiguous.
3. Detach all three standard streams. Redirect stdin from `/dev/null` and stdout/stderr to a log file.
4. Use `nohup` for ordinary detached jobs. Use `setsid` when the child must be isolated from the shell process group.
5. Put backgrounding around only the server process. Do not accidentally background the entire command chain.
6. Add finite timeouts to every readiness probe. Never let `curl`, log reads, or process waits block indefinitely.
7. Verify readiness instead of assuming that a successful spawn means the service is operational.
8. On failure, show the relevant log tail and return a non-zero status.

## Restart workflow

### 1. Define stable runtime files

Use a dedicated runtime directory and distinct files per service:

```sh
runtime_dir=/tmp/opencode
name=docusaurus-3122
pidfile="$runtime_dir/$name.pid"
logfile="$runtime_dir/$name.log"
mkdir -p "$runtime_dir"
```

### 2. Stop an existing instance safely

Prefer a validated PID file. Before killing a PID, confirm that it still exists and belongs to the expected service. Treat stale PID files as stale metadata, not as authority.

```sh
if [ -s "$pidfile" ]; then
  pid=$(cat "$pidfile")
  case "$pid" in
    ''|*[!0-9]*) pid='' ;;
  esac

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *"docusaurus serve"*)
        kill "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
        ;;
    esac
  fi
  rm -f "$pidfile"
fi
```

When a known TCP port uniquely identifies the service, port-based cleanup is an acceptable fallback:

```sh
pid=$(lsof -nP -tiTCP:3122 -sTCP:LISTEN 2>/dev/null | head -n 1 || true)
if [ -n "$pid" ]; then
  kill "$pid" 2>/dev/null || true
fi
```

Do not interpolate an empty PID into `kill`. Do not kill every process returned by a broad textual search without inspecting the candidates.

### 3. Start and detach the service

Run from the intended working directory, redirect every stream, and save the spawned PID immediately:

```sh
cd /home/installadm/dev/ssp/ssp-docs || exit 1
nohup npx docusaurus serve --port 3122 --no-open \
  </dev/null >"$logfile" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$pidfile"
```

When the launcher replaces itself or spawns children, the saved PID may be a wrapper. Prefer a project-native service manager when available. Otherwise, use the listening-port PID for later cleanup or launch a dedicated wrapper with explicit signal forwarding.

### 4. Probe readiness with a deadline

Prefer a bounded polling loop over a fixed long sleep:

```sh
ready=0
i=0
while [ "$i" -lt 40 ]; do
  if curl -fsS --max-time 2 --noproxy '*' \
      http://127.0.0.1:3122/ >/dev/null; then
    ready=1
    break
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi

  sleep 0.5
  i=$((i + 1))
done

if [ "$ready" -ne 1 ]; then
  printf '%s\n' 'Service failed to become ready.' >&2
  tail -n 80 "$logfile" >&2 || true
  exit 1
fi

printf '%s\n' 'up:200'
```

Use an application-specific health endpoint when one exists.

## Safe compact pattern

For Docusaurus on port 3122, use this shape instead of `pkill -f`:

```sh
runtime_dir=/tmp/opencode; pidfile="$runtime_dir/docusaurus-3122.pid"; logfile="$runtime_dir/docusaurus-3122.log"; mkdir -p "$runtime_dir"; old=$(lsof -nP -tiTCP:3122 -sTCP:LISTEN 2>/dev/null | head -n 1 || true); [ -z "$old" ] || kill "$old" 2>/dev/null || true; cd /home/installadm/dev/ssp/ssp-docs || exit 1; nohup npx docusaurus serve --port 3122 --no-open </dev/null >"$logfile" 2>&1 & pid=$!; printf '%s\n' "$pid" >"$pidfile"; i=0; while [ "$i" -lt 40 ]; do curl -fsS --max-time 2 --noproxy '*' http://127.0.0.1:3122/ >/dev/null && { printf '%s\n' 'up:200'; exit 0; }; kill -0 "$pid" 2>/dev/null || break; sleep 0.5; i=$((i + 1)); done; tail -n 80 "$logfile" >&2 || true; exit 1
```

## Temporary background work

When the background process is needed only during the current task, install cleanup before starting it:

```sh
pid=''
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

some_server </dev/null >"$logfile" 2>&1 &
pid=$!
```

Do not add an `EXIT` trap when the user explicitly wants the process to remain running after the command finishes.

## Diagnostics

If a background command does not return promptly, inspect these causes:

- A child retained stdout, stderr, or stdin from the shell tool.
- The process daemonized incompletely or is waiting for interactive input.
- A broad `pkill -f` matched the shell wrapper or its parent.
- The shell grouped/backgrounded the wrong part of a compound command.
- A readiness command lacks a timeout.
- The service crashed while the shell continued sleeping.

Use these diagnostics:

```sh
ps -o pid,ppid,pgid,sid,stat,cmd -p "$pid"
lsof -p "$pid" 2>/dev/null | head -n 40
ss -ltnp 2>/dev/null | grep ':3122 '
tail -n 100 "$logfile"
```

## Reporting

After managing a background task, report:

- whether the process was stopped, started, or restarted;
- the PID or listening port used to identify it;
- the readiness result;
- the log-file location;
- any cleanup limitation, such as an `npx` wrapper PID differing from the final Node PID.
