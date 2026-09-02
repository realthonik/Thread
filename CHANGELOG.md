# Changelog

## Unreleased

### Added

- Structured service Method failures with stable error codes, service and remote context, and reliable distinction from legitimate nil returns.
- Built-in argument validators, per-service and per-remote payload limits, and per-remote policy overrides.
- Promise cancellation hooks, cancellation errors and states, and configurable unhandled rejection reporting.
- Promise-aware `ThreadInit`, `ThreadStart`, and `ThreadStop`, with reverse dependency shutdown and lifecycle status inspection.
- Exact replicated service manifests consumed by `Channel.BuildClient`.
- A versioned generator for package metadata, Wally metadata, service manifests, docs badges, static Luau client types, and typed `Thread.Clients` builders.
- Rojo projects, Rokit tool pins, StyLua and Selene configuration, GitHub Actions CI, and a real server/client Studio integration suite.

### Changed

- Per-player rate limiting now uses continuously refilled token buckets instead of time-window arrays. Repeated warnings are throttled per player and remote.
- Package version and release-tag validation now share `thread.config.json` as their source of truth.

### Fixed

- Client service proxies now wait for a completed Remote manifest and successful service lifecycle before becoming available.
- Failed services no longer run `ThreadStart`, and services with failed dependencies are skipped.
- Property initial synchronization is revisioned so concurrent updates cannot be missed; teardown now disconnects internal listeners.
- Remote calls preserve nil arguments and multiple return values, including middleware transformations.
- Per-player Properties can use nil as an explicit override value.
- `Promise.retry` handles synchronous failures on every attempt, and settled Promises release queued callbacks.
- Promise self-resolution, adopted-Promise settlement races, cancellation reentrancy, event-predicate failures, rate limits, and invalid configuration values now fail safely.
- Services that fail during `ThreadStart` still receive `ThreadStop`, and cancelling a lifecycle observer cannot cancel framework startup or shutdown.
- Service definitions, middleware, remote policies, payload limits, generated manifests, and malformed remote responses now fail early instead of being silently truncated or ignored.
- Fixed `TimerUtil`, `TableUtil.Filter`, immutable `Option`/`EnumList` values, and destroyed `Trove` behavior.
- Installation and test paths now match the repository's `src/` layout.

## v1.1.0

### Added

- **MathUtil**
- **TimerUtil**

## v1.0.1

### Fixed
- **Middleware now actually applies to Signals and Properties, not just Methods.** `Channel.WrapService` previously only ran `Inbound`/`Outbound` middleware for `Client` methods — a service's `Middleware` field silently had no effect on Signals or Properties, despite the docs implying otherwise. Fixed: `Signal:Connect` now runs `Inbound` middleware on client→server fires; `Signal:Fire`/`:FireAll`/`:FireExcept` and `Property:Set`/`:SetFor` now run `Outbound` middleware before sending. `FireAll`/`FireExcept`/`Property:Set` call middleware with `player = nil` since there's no single target. Covered by two new tests in `Tests/Thread.spec.luau`.

## 1.0.0

Closes out the remaining gaps versus Knit that the beta left open, and adds hand-written equivalents of the most-used [RbxUtil](https://github.com/Sleitnick/RbxUtil) modules (the same utility collection Knit itself is built on) as new, independent Util modules. Still zero external dependencies — every module below was written from scratch for this project; nothing is vendored or pulled in via Wally.

### Added — closing the Knit gap
- **Per-player Property overrides**: `Property:SetFor(player, value)`, `Property:GetFor(player)`, `Property:ClearFor(player)` — the last remaining feature Knit's `RemoteProperty` had that Thread's `Property` didn't. `Property:Set(value)` now also correctly skips broadcasting over an active per-player override.
- **Richer Promise**: `Promise.race`, `Promise.some`, `Promise.delay`, `Promise.retry`, `Promise.fromEvent`, and an instance method `Promise:timeout(seconds, err?)` — closing the gap with evaera's promise library that Knit uses.

### Added — new Util modules (`Packages/Util/`, also exposed as `Thread.Signal`, `Thread.Trove`, `Thread.TableUtil`, `Thread.Option`, `Thread.EnumList`)
- **`Signal`** — a fast, pure-Luau event class (pooled-coroutine linked list, the same well-known shape RbxUtil's own Signal uses) independent of BindableEvent. `.new()`, `.Wrap(rbxSignal)`, `.Is(obj)`, `:Connect`, `:Once`, `:Fire`, `:Wait`, `:DisconnectAll`, `:GetConnections`, `:Destroy`.
- **`Trove`** — a cleanup/janitor utility for tracking Instances, connections, functions, threads, or any Destroy/Disconnect-able object and tearing them all down with one call. `.new()`, `:Add`, `:Remove`, `:Connect`, `:Clone`, `:Construct`, `:Clean`, `:Destroy`, `:Extend` (nested, auto-cleaned sub-trove), `:AttachToInstance`.
- **`TableUtil`** — `Copy` (shallow/deep), `Sync`, `Reconcile`, `Lock` (deep freeze), `SwapRemove`, `SwapRemoveFirstValue`, `Reverse`, `Shuffle`, `Map`, `Filter`, `Reduce`, `Find`, `Every`, `Some`, `Keys`, `Values`, `IsEmpty`, `Length`.
- **`Option`** — a Rust-style `Option<T>` for explicit nil-handling: `Option.Some/Wrap/None/Is`, `:IsSome`, `:IsNone`, `:Match`, `:Unwrap`, `:Expect`, `:UnwrapOr`, `:UnwrapOrElse`, `:And`, `:AndThen`, `:Or`, `:OrElse`, `:Contains`.
- **`EnumList`** — custom, strongly-comparable enums: `EnumList.new(name, {...names})`, `:BelongsTo`, `:GetEnumItems`, `:GetName`, plus `:FromName`/`:FromValue` lookups.

### Tests
- Added coverage for per-player Property overrides, `Promise.race/some/retry/timeout/fromEvent`, and all five new Util modules to `Tests/Thread.spec.luau`.

## beta

Rewrite on top of the original [mm5ck/Wire](https://github.com/mm5ck/Wire) v1.1.1, addressing the gaps identified when comparing it against Knit. Everything stays pure Luau for Roblox — **no Wally, no third-party packages, nothing outside the engine's own APIs** (Attributes, RemoteEvent/RemoteFunction/UnreliableRemoteEvent, Instance).

### Added
- **Typed `Client` tables** on services (`Thread.CreateService({ Client = { ... } })`). Methods, `Thread.CreateSignal()`, `Thread.CreateUnreliableSignal()`, and `Thread.CreateProperty(initial)` are auto-bound to real Remotes by `Channel.WrapService` — no more manually matching string names between `Channel.On` calls on the server and `Channel.FireServer` calls on the client.
- **`Channel.BuildClient(serviceName)`** — client-side counterpart that discovers a service's Remotes (via a `ThreadKind` Attribute set on each Remote) and returns a ready-to-use proxy: `proxy:Method(...)`, `proxy.SomeSignal:Connect(fn)`, `proxy.SomeProperty:Get()`.
- **Dependency ordering**: `Thread.CreateService({ Dependencies = { "OtherService" } })`. Services are initialized in topological order; circular or unknown dependencies are detected up front with a clear error instead of silently racing.
- **Middleware**: per-service `Middleware = { Inbound = {...}, Outbound = {...} }`, run for every wrapped Client method/Signal call. A middleware fn can mutate the args table and return `false` to drop the call.
- **`Thread.Configure({ Debug = bool, HaltOnCriticalFailure = bool })`** — central place to toggle logging and startup behaviour instead of poking module fields directly.
- **`Thread.GetServices()`**, **`Thread.Unregister(name)`**, and `Thread.Register()` now returns a `{ Module, Success, Result, Error }[]` report instead of nothing.
- **`Channel.Destroy(serviceName)`** — tears down every Remote created for a service (useful for hot-reload/testing).
- **`Promise.allSettled`** for "run everything, tell me what failed" flows.
- Exported Luau types (`ServiceDef`, `Service`, `Middleware`, `RegisterResult`, ...) for editor autocomplete and type-checking.
- A small, dependency-free test runner (`Tests/TestRunner.luau`) plus a real test suite (`Tests/Thread.spec.luau`) covering Promise, dependency ordering, circular-dependency detection, `Thread.Register`, and the new Channel signal/property wrapping — no TestEZ, no Wally.
- `LICENSE` (MIT) instead of a one-line README disclaimer.

### Changed
- **`Thread.Debug` / `Channel.Debug` now default to `false`** (was `true`) — no console spam in production by default.
- **Critical service failures no longer hard-crash the calling script.** `Thread.Start()` always returns the start Promise; on a critical failure it now *rejects* that Promise (so `Thread.Start():catch(warn)` works like in Knit) instead of unconditionally calling `error()`. The old hard-crash behaviour is still available via `Thread.Configure({ HaltOnCriticalFailure = true })`.
- Service init/start order is now deterministic (topological, falling back to registration order) instead of relying on Lua's unspecified `pairs()` iteration order.
- Internal `Channel` container/cache logic reworked to support per-service namespacing without breaking the existing low-level API.

### Unchanged (fully backwards compatible)
- `Channel.On` / `FireClient` / `FireAll` / `FireServer` / `SetFunction` / `InvokeServer` / `InvokeClient` / `Event` / `Function` — the original string-keyed low-level API still works exactly as before, for cases where a full service `Client` table is overkill.
- Per-player rate limiting, `InvokeClient` timeout, handler error isolation.
- Two-phase service lifecycle (`ThreadInit` / `ThreadStart`).

### Known limitations (intentionally out of scope)
- `Property` replicates one value to *all* clients; there's no per-player property override (Knit's `RemoteProperty:SetFor(player, value)`). Adding it is straightforward if needed, but it wasn't in the original Wire and was left out to keep the diff focused.
- No package-manager distribution (by request — this stays a manual drop-in, Rojo-project-optional, copy-paste module).
