# Lab 12 — QuickNotes-style Moscow-time endpoint on Spin

## Tools and source

The HTTP component was scaffolded with `spin new -t http-go moscow-time --accept-defaults` from the Spin 3.4.0 template, then adapted to the required endpoint. Its source and manifest are [main.go](../wasm/moscow-time/main.go), [spin.toml](../wasm/moscow-time/spin.toml), [go.mod](../wasm/moscow-time/go.mod), and [go.sum](../wasm/moscow-time/go.sum). The scaffold pins `github.com/spinframework/spin-go-sdk/v2` at `v2.2.1`, uses `tinygo build -target=wasip1 -buildmode=c-shared -no-debug`, routes `/time`, and grants no outbound hosts. The build used Spin 3.4.0, TinyGo 0.41.1 with Go 1.26.0, and Linux/amd64.

The standalone CLI bonus lives in [wasm-cli/main.go](../wasm-cli/main.go). Its runtime was Wasmtime 49.0.3. `hyperfine` was 1.19.0.

## Task 1 — HTTP component

```text
$ cd wasm/moscow-time && spin build
Building component moscow-time with `tinygo build -target=wasip1 -buildmode=c-shared -no-debug -o main.wasm .`
Finished building all Spin components
$ stat -c %s main.wasm
371218
$ spin up --listen 127.0.0.1:3000
Serving http://127.0.0.1:3000
Available Routes:
  moscow-time: http://127.0.0.1:3000/time
$ curl -i http://127.0.0.1:3000/time
HTTP/1.1 200 OK
content-type: application/json

{"unix":1792088760,"iso":"2026-10-15T21:26:00+03:00","hour_minute":"21:26","timezone":"Europe/Moscow"}
```

`POST /time` returned HTTP 405 with `Allow: GET`. The endpoint obtains the current instant and formats it in a fixed UTC+3 zone; it does not need outbound network or zoneinfo files.

### Design answers a–d

a) The browser `js/wasm` target expects JavaScript host bindings and Go's browser glue. The `wasip1` target does not have the browser DOM or arbitrary JavaScript APIs; it gains a standard, capability-limited server-side host interface that Spin can run outside a browser.

b) Spin expects the HTTP component's exported handler ABI, not an ordinary command's `_start` entry point. The scaffold's `-buildmode=c-shared` makes TinyGo emit the exports expected by the Spin Go SDK host. Removing it would not produce a working Spin HTTP handler.

c) `allowed_outbound_hosts = []` gives this component no HTTP egress capability. The host explicitly mediates allowed destinations; code inside the module cannot grant itself more. Docker's `--network none` removes external network connectivity at the Linux-network-namespace level for the whole container. Spin's policy is per-component and can permit only particular hosts when needed; neither setting by itself replaces all filesystem or process restrictions.

d) A separate TinyGo/WASI probe using `time.LoadLocation("Europe/Moscow")` returned `zone=UTC error=unknown time zone Europe/Moscow`: the expected zoneinfo database was unavailable. The submitted handler therefore uses `time.FixedZone("MSK", 3*60*60)` and avoids reflection-heavy JSON encoding by formatting fixed fields directly.

## Task 2 — measured comparison with Lab 6

Test rig: Windows 11 host, Ubuntu under WSL2 (Linux 6.6.87.2, x86_64), Intel Core i5-12450H with 8 logical CPUs, Docker Engine 29.1.3. The Lab 6 Dockerfile was built as `quicknotes:lab6` in the local Linux daemon. Spin ran from the WSL native filesystem; Docker used host networking. Both were measured via `127.0.0.1` after the build activity had finished. Image size is the `docker image ls` size; module size is its exact file length.

Warm timing used `hyperfine --shell=none --warmup 5 --runs 50` around `curl -fsS -o /dev/null` for Spin `/time` and Docker `/health`. The p50 is the median of the 50 elapsed times; p95 is the nearest-rank 95th percentile. The raw samples are [spin-warm.json](evidence/spin-warm.json) and [docker-warm.json](evidence/docker-warm.json).

For cold starts, [bench-cold.sh](../wasm/bench-cold.sh) stopped each runtime, timed process/container launch through the first successful HTTP response, and repeated this five times with the image and module already cached. The raw values are in [cold-start.csv](evidence/cold-start.csv).

| Dimension | Lab 6 Docker | Lab 12 WASM/Spin |
|---|---:|---:|
| Artifact size | 15.7 MB image | 371,218 bytes (0.354 MiB) module |
| Cold start to first HTTP 200, p50 | 963 ms | 103 ms |
| Warm request p50 | 8.538 ms | 12.214 ms |
| Warm request p95 | 10.530 ms | 14.878 ms |

Cold samples in milliseconds were Spin `843, 86, 61, 104, 103` and Docker `1226, 935, 889, 1090, 963`. The first Spin sample was an outlier. These are end-to-end localhost measurements: they include launcher and `curl` overhead, not just Wasmtime instantiation, and the endpoints perform different work (`/time` versus `/health`). In these measurements Spin started faster but Docker answered warm requests faster; the result should not be generalized to all workloads.

### Design answers e–g

e) Docker's cold path includes the Docker CLI/daemon, creating the container and network namespace, mounting the root filesystem, and starting the Go process. The image had already been pulled, so registry download was excluded. Spin's cold path includes starting the Spin host, loading/compiling the module and instantiating it for the first request. This experiment includes both launchers and the first HTTP probe; it does not isolate their individual contributions.

f) Small, stateless, high-fan-out handlers or untrusted plugins benefit from portable small modules and tight capabilities. Docker is still a better fit for mature OS-level dependencies, long-running stateful services, and tools that expect a full Linux process environment. This endpoint is intentionally smaller in scope than the full QuickNotes API.

g) A WASI module cannot directly issue arbitrary Linux syscalls or open ambient host files/sockets; the host must grant interfaces. That makes an attack such as reading another tenant's filesystem or opening an unapproved outbound socket harder than in a broadly privileged Linux container. The host runtime itself remains part of the trusted computing base, so this is not a claim of absolute isolation.

## Bonus — standalone WASI CLI versus Spin HTTP

The same four JSON fields are generated by [wasm-cli/main.go](../wasm-cli/main.go), which reads `REQUEST_METHOD` and `PATH_INFO` and writes one response to stdout:

```text
$ cd wasm-cli
$ tinygo build -o main.wasm -target=wasi -no-debug ./main.go
$ wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm
{"unix":1792088779,"iso":"2026-10-15T21:26:19+03:00","hour_minute":"21:26","timezone":"Europe/Moscow"}
```

The CLI module was 196,260 bytes (0.187 MiB), versus 371,218 bytes for the Spin component. Fifty `wasmtime run` invocations, each launching a fresh process, had p50 9.719 ms and p95 17.165 ms; [wasi-cli-runs.json](evidence/wasi-cli-runs.json) has the raw timings. Spin's 103 ms cold-start figure includes launching a persistent HTTP server and obtaining its first network response, so it is not a like-for-like measurement against a CLI invocation. The Spin server's steady-state HTTP p50 was 12.214 ms.

### Design answers h–j

h) The Spin artifact is a `wasi-http` handler component, not a CLI program that reads environment variables and prints a response from `_start`. With Wasmtime 49.0.3, `wasmtime run` on this artifact exited successfully but produced no HTTP response: it did not create a listening server. A host such as Spin or `wasmtime serve` must supply the HTTP trigger.

i) Spin uses Wasmtime to execute components but adds the persistent HTTP host, routing from `spin.toml`, component lifecycle management, the Go SDK's HTTP mapping, and outbound-host policy. Bare `wasmtime run` starts a command component once and exits.

j) Per-invocation WASI CLI fits batch or event jobs that take inputs and produce one output. A persistent Spin HTTP host fits a low-latency, request-driven API endpoint such as `/time`.
