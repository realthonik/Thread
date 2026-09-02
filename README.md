# Thread

A lightweight Roblox framework for building scalable games with a clean **Service Architecture**, a **typed Communication System**, and a small **Promise** implementation for startup sequencing.

Based on the previous model "Wire v1.1.1. by me". Thread includes service `Client` tables, Signals and Properties, middleware, dependency ordering, cancellable Promises, validation, generated client types, and hand-written equivalents of common utility modules. The runtime stays dependency-free. Wally and Rokit manifests are included for packaging and development tooling only.

This document explains not just *what* each piece does, but *how it works internally* and *when to reach for it* — it's meant to be read top to bottom once, then used as a reference afterward.

## Table of Contents

- [Project Anatomy](#project-anatomy)
- [Installation](#installation)
- [Core Concept: Services](#core-concept-services)
- [Bootstrapping: Register + Start](#bootstrapping-register--start)
- [The Client Table: Methods, Signals, Properties](#the-client-table-methods-signals-properties)
- [How Networking Actually Works Under the Hood](#how-networking-actually-works-under-the-hood)
- [Dependencies Between Services](#dependencies-between-services)
- [Middleware](#middleware)
- [Critical Services & Startup Failure](#critical-services--startup-failure)
- [Rate Limiting & Timeouts](#rate-limiting--timeouts)
- [Configuration](#configuration)
- [The Low-Level Channel API](#the-low-level-channel-api)
- [Promise — Complete Reference](#promise--complete-reference)
- [Util Modules — Complete Reference](#util-modules--complete-reference)
- [Server vs. Client Cheat Sheet](#server-vs-client-cheat-sheet)
- [Exported Luau Types](#exported-luau-types)
- [Generation, Formatting, and Testing](#generation-formatting-and-testing)
- [Troubleshooting](#troubleshooting)
- [Full API Reference Tables](#full-api-reference-tables)

## Project Anatomy

```
Thread/
├── src/                  -- copy/map this folder to ReplicatedStorage/Packages
│   ├── Thread.luau      -- service registry + lifecycle + startup sequencing
│   ├── Channel.luau     -- everything networking-related (RemoteEvents/Functions)
│   ├── Promise.luau     -- async primitive used by startup and shutdown
│   ├── Generated/       -- generated metadata, runtime manifest, and typed clients
│   └── Util/
│       ├── Signal.luau      -- fast in-process pub/sub (no Instance overhead)
│       ├── Trove.luau       -- cleanup/janitor helper
│       ├── TableUtil.luau   -- table helper functions
│       ├── Option.luau      -- explicit nil-handling wrapper
│       ├── EnumList.luau    -- custom, comparable enums
│       ├── MathUtil.luau    -- lerp, range remapping, fuzzy equality
│       └── TimerUtil.luau   -- debounce/throttle function wrappers
├── Tests/
│   ├── TestRunner.luau   -- ~30-line assert-based test runner, no TestEZ
│   └── Thread.spec.luau  -- the actual test suite
├── generated/            -- generated service manifest and static client types
├── default.project.json  -- standard Rojo mapping
├── thread.config.json    -- source of truth for versions and generated files
├── rokit.toml            -- pinned development toolchain
├── wally.toml            -- generated package manifest
├── README.md
├── CHANGELOG.md
└── LICENSE
```

The runtime requires nothing outside `src/`. You can copy it directly, map it with the included Rojo project, or consume the package through Wally.

## Installation

Copy the contents of `src/` (including the `Util/` subfolder) into `ReplicatedStorage/Packages/`, either by dragging the files into Studio directly or by mapping `src` there in your Rojo project. Rojo is optional.

```
ReplicatedStorage
└── Packages
    ├── Thread.luau
    ├── Channel.luau
    ├── Promise.luau
    └── Util
        ├── Signal.luau
        ├── Trove.luau
        ├── TableUtil.luau
        ├── Option.luau
        ├── EnumList.luau
        ├── MathUtil.luau
        └── TimerUtil.luau
```

`Util` **must** be a `Folder` Instance containing the seven modules as children — `Thread.luau` requires them via `script.Parent.Util.Signal` etc., so the hierarchy has to match exactly.

There is no fixed location for your own game code — `Thread.Register(folder)` just points at whatever folder you keep your services/controllers in. The conventional layout is:

```
ServerScriptService
└── Services
    ├── MoneyService.luau
    └── DataService.luau

StarterPlayer
└── StarterPlayerScripts
    └── Controllers
        └── HudController.luau
```

## Core Concept: Services

A **Service** is a plain Lua table describing one feature of your game. You define it once with `Thread.CreateService({...})`, then attach normal functions to it as its methods.

```lua
-- ServerScriptService/Services/MoneyService.luau
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

local MoneyService = Thread.CreateService({
    Name = "MoneyService", -- required, must be unique
})

local balances = {}

function MoneyService:GetMoney(player)
    return balances[player] or 0
end

function MoneyService:GiveMoney(player, amount)
    balances[player] = self:GetMoney(player) + amount
end

return MoneyService
```

A service can optionally define three lifecycle methods:

- **`ThreadInit(self)`** — runs first, for every service, in dependency order (see [Dependencies](#dependencies-between-services)). Use this to set up internal state and grab references to other services via `Thread.GetService(...)`. Client remotes are already bound at this point (see below), so it's safe to `:Connect()` your own signals here.
- **`ThreadStart(self)`** — runs after the initialization phase, for services whose initialization and dependencies succeeded. Use this for logic that depends on other healthy services being fully initialized.
- **`ThreadStop(self)`** runs during `Thread.Stop()` in reverse dependency order, so dependents stop before the services they use.

All three lifecycle methods may return a `Thread.Promise`. Thread waits for that Promise before moving to the next dependent service. A failed or cancelled lifecycle Promise is handled like a synchronous lifecycle error.

The exact same `Thread.CreateService({...})` call works identically on the client — see [Server vs. Client Cheat Sheet](#server-vs-client-cheat-sheet) for the one thing that differs (the `Client` field).

## Bootstrapping: Register + Start

Two calls, once per side (server and client each need their own):

```lua
-- ServerScriptService/Server.server.lua
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

Thread.Register(game:GetService("ServerScriptService").Services)
Thread.Start():catch(warn)
```

```lua
-- StarterPlayerScripts/Client.client.lua
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

Thread.Register(script.Parent.Controllers)
Thread.Start():catch(warn)
```

**What `Thread.Register(folder, recursive?)` actually does:** it walks every `ModuleScript` directly inside `folder` (pass `recursive = true` to walk nested subfolders too) and calls `require()` on each one. Since your service files call `Thread.CreateService({...})` at the top level, simply *requiring* the module is what registers it — `Thread.Register` never has to know your service names in advance. It returns a report array so you can inspect what loaded:

```lua
local results = Thread.Register(folder)
for _, r in ipairs(results) do
    if not r.Success then
        warn("Failed to load", r.Module.Name, ":", r.Error)
    end
end
```

**What `Thread.Start()` actually does, step by step:**

1. Collects every registered service and computes a dependency order (topological sort — see [Dependencies](#dependencies-between-services)).
2. For every service with a `Client` table, calls `Channel.WrapService(...)` to bind it to real Remote instances (server-only — silently skipped/warned on the client, see [Client Table](#the-client-table-methods-signals-properties)).
3. Calls `ThreadInit` on every service, in dependency order.
4. Calls `ThreadStart` on every healthy service, in dependency order, after the initialization phase finishes.
5. Publishes exact service manifests only after startup completes.
6. Resolves the start `Promise` returned by `Thread.OnStart()`.

If a service marked `Critical = true` fails at step 3 or 4, steps after it are skipped and the start `Promise` **rejects** instead of resolving (see [Critical Services](#critical-services--startup-failure)).

`Thread.OnStart()` returns an observer `Promise` for the same startup result and can be called from anywhere, any number of times, from code that isn't the one that called `Thread.Start()`. Cancelling one observer does not cancel framework startup or other observers:

```lua
Thread.OnStart():andThen(function()
    local MoneyService = Thread.GetService("MoneyService") -- safe now, everything is started
end):catch(warn)
```

Shutdown is Promise-based and idempotent:

```lua
Thread.Stop():await()
-- Thread.OnStop() observes the same shutdown result after Stop has begun.
```

Remember: **the server and the client each run their own separate copy of `Thread`.** The server's `Thread._Register`, `Thread.OnStart()`, etc. are entirely independent Lua state from the client's — they don't communicate with each other automatically. That's what `Channel` (below) is for.

## The Client Table: Methods, Signals, Properties

This is the feature that replaces manually wiring up `RemoteEvent`/`RemoteFunction` instances. A service can declare a `Client` table describing exactly what it exposes to clients:

```lua
local MoneyService = Thread.CreateService({
    Name = "MoneyService",
    Client = {
        -- 1) A METHOD: the client calls this and gets a return value back.
        GetMoney = function(self, player)
            return self.Server:GetMoney(player)
        end,

        -- 2) A SIGNAL: a one-off push event, server -> client.
        MoneyChanged = Thread.CreateSignal(),

        -- 3) A PROPERTY: a value kept in sync with clients automatically.
        Jackpot = Thread.CreateProperty(0),
    },
})
```

A few things worth understanding here:

- Every `Client` method receives `self` (the `Client` table itself — note **not** the outer service) and `player` (automatically injected — the client can't fake this) as its first two arguments, then whatever the client passed.
- `self.Server` is a back-reference to the outer service table, so a `Client` method can call the "real" implementation: `self.Server:GetMoney(player)`.
- `Thread.CreateSignal()` / `Thread.CreateProperty(v)` are just **markers**. When `Thread.Start()` calls `Channel.WrapService`, it walks the `Client` table and replaces each marker **in place** with a real Signal/Property object. So by the time `ThreadInit` runs, `self.Client.MoneyChanged` is already a working object, not a marker.
- `Thread.CreateSignal`, `Thread.CreateUnreliableSignal`, and `Thread.CreateProperty` are literally the same functions as `Channel.CreateSignal`/`Channel.CreateUnreliableSignal`/`Channel.CreateProperty` — `Thread` just re-exports them so you don't have to reach into `Thread.Channel` for something you'll use constantly.

### Which one do I use?

| Situation | Use |
|---|---|
| Client asks a one-time question and needs an answer ("how much money do I have?") | **Method** |
| Server wants to push a one-off event ("you leveled up", "explosion at X") | **Signal** |
| A value needs to stay in sync and be readable at any time, including for a client who joins late | **Property** |
| A cosmetic, high-frequency event where occasional packet loss is fine (footstep VFX) | **UnreliableSignal** (`Thread.CreateUnreliableSignal()`) |

### Using a Signal

```lua
-- Server
function MoneyService:GiveMoney(player, amount)
    balances[player] = self:GetMoney(player) + amount
    self.Client.MoneyChanged:Fire(player, balances[player])       -- to one player
    self.Client.MoneyChanged:FireAll(balances[player])              -- to everyone
    self.Client.MoneyChanged:FireExcept(player, balances[player])   -- to everyone but `player`
end
```

```lua
-- Client
MoneyService.MoneyChanged:Connect(function(newBalance)
    print("New balance:", newBalance)
end)
```

A Signal built from `Thread.CreateSignal()` can also be fired *from* the client back to the server (`MoneyService.SomeSignal:Fire(...)` on the client) — it's a two-way object, just used one-directionally in the example above. On the server, `:Connect(fn)` receives `(player, ...)`.

### Using a Property

```lua
-- Server
self.Client.Jackpot:Set(500)                     -- new value, broadcast to everyone (see override note below)
local current = self.Client.Jackpot:Get()        -- read the shared default back

-- Per-player overrides (e.g. a personalized value only one player sees):
self.Client.Jackpot:SetFor(player, 9999)
self.Client.Jackpot:GetFor(player)               -- returns 9999 for that player, the default for everyone else
self.Client.Jackpot:ClearFor(player)              -- back to the shared default
```

```lua
-- Client
print(MoneyService.Jackpot:Get())                -- last known value, synchronously

MoneyService.Jackpot:Observe(function(value)
    print("Jackpot is now", value)
end)
-- Observe calls your function IMMEDIATELY with the current value, then again
-- on every future change. Always use Observe over a manual :Get() + polling.
```

`Property:Set(value)` broadcasts to every currently-connected client **except** those with an active `:SetFor` override — so setting the shared default never clobbers a personalized value. A newly-created `Property` fetches its own current value synchronously the first time a client builds it, so late-joining players never see a stale/default value.

There's also `Property:Destroy()` (both sides), which disconnects the internal `PlayerRemoving` connection a server-side Property keeps around to clean up per-player overrides when someone leaves. You won't normally call this directly — `Channel.Destroy(serviceName)` tears down the underlying Remotes for you — it's there mainly for advanced manual-teardown scenarios.

## How Networking Actually Works Under the Hood

Understanding this makes debugging a lot easier.

1. The first time `Channel.luau` loads (server or client), it creates (or, on the client, waits for) a folder at `ReplicatedStorage.ThreadChannel`. All Remote instances live under here.
2. When the server calls `Channel.WrapService("MoneyService", clientTable, opts)`, for every key in `clientTable` it creates one Remote object per key, under a namespaced folder: e.g. a `Method` named `GetMoney` becomes a `RemoteFunction` at `ReplicatedStorage.ThreadChannel.RemoteFunction.MoneyService.GetMoney`. Namespacing by service name means two different services can both expose a method called `GetMoney` without colliding.
3. Every Remote gets a Roblox **Attribute** called `ThreadKind` set to `"Method"`, `"Signal"`, or `"Property"`. This is how the client later figures out how to wrap each Remote — it's pure metadata, doesn't touch Lua state at all.
4. After every Remote has been created and the service lifecycle has completed successfully, Thread creates a ready marker at `ReplicatedStorage.ThreadChannel.Services.<ServiceName>`.
5. `Channel.BuildClient("MoneyService")` waits for that ready marker, reads its exact JSON manifest, waits for the listed Remote instances, and builds the appropriate wrappers. This prevents clients from seeing an incomplete or uninitialized service.

None of this requires you to know service names or method names on both ends independently — the server's `Client` table *is* the single source of truth; the client just reads it back out of the Remote hierarchy.

Wrapped methods use a protocol envelope internally. `BuildClient` decodes successful values, including nil holes and multiple returns. Failures throw a structured table through `pcall` with `Code`, `Message`, `Service`, and `Remote` fields. Use `Channel.IsRemoteError(value)` to distinguish these failures from ordinary local errors. The low-level string API remains unchanged.

### Validation and Payload Limits

Every wrapped method and client-to-server Signal is capped at 64 KiB by default. Set `MaxPayloadBytes` on a service or one remote policy to change it. Policies also provide built-in validators:

```lua
local InventoryService = Thread.CreateService({
    Name = "InventoryService",
    MaxPayloadBytes = 8 * 1024,
    RemotePolicies = {
        Buy = {
            Arguments = {
                Thread.Validators.StringMaxLength(64),
                Thread.Validators.Integer,
            },
            AllowExtraArguments = false,
            RateLimit = 5,
        },
    },
    Client = {},
})
```

Built-ins include `Any`, `String`, `Number`, `FiniteNumber`, `Integer`, `Boolean`, `Table`, `Instance`, `Player`, `Optional(validator)`, `StringMaxLength(bytes)`, and `Array(itemValidator?, maxLength?)`.

## Dependencies Between Services

```lua
Thread.CreateService({
    Name = "InventoryService",
    Dependencies = { "DataService" }, -- DataService's ThreadInit is guaranteed to run first
    ThreadInit = function(self)
        self.Data = Thread.GetService("DataService")
    end,
})
```

Internally, `Thread.Start()` builds a dependency graph from every service's `Dependencies` list and runs a topological sort (depth-first, tracking a "visiting" state per node) before calling any `ThreadInit`. Two failure modes are caught **before** any service code runs at all, with a precise error message:

- **Unknown dependency**: a service lists a name that was never registered.
- **Circular dependency**: e.g. A depends on B, B depends on A. The error message includes the exact cycle (`A -> B -> A`).

Either failure rejects `Thread.OnStart()` the same way a [critical failure](#critical-services--startup-failure) does — it does not crash your script by default.

You only need `Dependencies` when a service reads another service's state **during `ThreadInit`**. If two services only reference each other from `ThreadStart` (which always runs after every `ThreadInit`) or later, you don't need to declare anything — the two-phase lifecycle already guarantees the order you need.

## Middleware

Middleware runs for every wrapped `Client` method and Signal call on a service, either transforming or rejecting the call before it reaches your code (`Inbound`) or before the result goes back to the client (`Outbound`).

```lua
Thread.CreateService({
    Name = "ShopService",
    Client = {
        Purchase = function(self, player, itemId)
            -- ... itemId is guaranteed to be a string by the time we get here
        end,
    },
    Middleware = {
        Inbound = {
            function(player, args)
                if typeof(args[1]) ~= "string" then
                    return false -- returning false drops the call entirely; your handler never runs
                end
                return true
            end,
        },
        Outbound = {
            function(player, args)
                -- args[1] is what your handler returned; you could sanitize/log it here
                return true
            end,
        },
    },
})
```

A middleware function receives `(player, args)` where `args` is a plain array of the call's arguments (inbound) or its return value(s)/broadcast payload (outbound). It can **mutate `args` in place** to transform them, and returns `false` to stop the chain. Multiple middleware functions run in the order given, each seeing the previous one's mutations.

`Middleware` is one set defined per-service and applies to **everything** in that service's `Client` table, with slightly different meanings depending on what it's attached to:

| On a... | `Inbound` runs when... | `Outbound` runs when... |
|---|---|---|
| Method | the client calls it, before your handler runs. Returning `false` prevents execution and produces `MIDDLEWARE_REJECTED`. | your handler returns, before the result is sent back. Returning `false` produces `OUTBOUND_REJECTED`. |
| Signal | the client fires it (received via `:Connect` on the server), before your handler runs. Returning `false` means your handler never sees that fire. | the server calls `:Fire`/`:FireAll`/`:FireExcept`, before the event actually goes out. Returning `false` silently drops that specific send. |
| Property | — (there's no "inbound" for a Property; the client never pushes data through one) | the server calls `:Set`/`:SetFor`, before the new value is stored and broadcast. Returning `false` leaves the property's value completely unchanged. |

For `Outbound` on `Signal:FireAll`/`:FireExcept` and `Property:Set`, there's no single target player yet (it's going to everyone), so middleware there is called with `player = nil` — write your middleware to handle that if you use those.

Use middleware for validation/logging/transformation that applies across **multiple** methods/signals/properties on a service. For a check that only applies to one specific method, a plain `if`/`assert` at the top of that method is simpler and easier to read.

## Critical Services & Startup Failure

```lua
Thread.CreateService({
    Name = "DataService",
    Critical = true, -- a failed ThreadInit/ThreadStart here rejects the whole Thread.Start()
})

Thread.Start():catch(function(err)
    warn("Startup failed:", err)
    -- e.g. kick all players, since data can't load
end)
```

If a service marked `Critical = true` throws inside `ThreadInit` or `ThreadStart`, `Thread.Start()` stops processing further services and the `Promise` returned by `Thread.Start()`/`Thread.OnStart()` **rejects** with a descriptive message. By default this does **not** crash the script that called `Thread.Start()` — you decide what to do with the rejection via `:catch()`.

If you'd rather have the old, harder failure mode (immediately `error()`, killing the calling script), opt in explicitly:

```lua
Thread.Configure({ HaltOnCriticalFailure = true })
```

Non-critical services that throw during `ThreadInit`/`ThreadStart` log a warning and are skipped. Services depending on them are skipped too, while unrelated services continue normally. Only mark a service `Critical` if the game genuinely can't function without it (typically: your data-persistence service).

## Rate Limiting & Timeouts

Two protections apply automatically to every Client method/Signal (and to the low-level `Channel.On`/`SetFunction`), without you having to configure anything:

- **Per-player token buckets**: each Remote has a burst capacity equal to its calls-per-second limit and refills continuously. Defaults are 30 for Signals and 20 for Methods. Override a service or one `RemotePolicies` entry. Signal calls over the limit are dropped; Method calls receive a structured `RATE_LIMITED` error. Repeated warnings are throttled per player and remote.
- **Payload limits**: `Channel.DefaultMaxPayloadBytes = 65536` applies to inbound arguments and wrapped Method responses. Unsupported values, cycles, and nesting beyond 32 levels are rejected before handlers run.
- **`Channel.InvokeClient` timeout**: server-to-client `InvokeClient` calls give up after `Channel.InvokeClientTimeout` seconds (default 10) instead of hanging forever if the client is unresponsive or disconnects mid-call.

There is currently **no** timeout on client-to-server `InvokeServer` calls (i.e. calling a `Client` Method from the client) — that's standard Roblox behavior, not something Thread adds protection for. If you need one, wrap the call: `Promise.new(function(resolve) resolve(MyService:SomeMethod()) end):timeout(5)`.

## Configuration

```lua
Thread.Configure({
    Debug = true,                    -- verbose [Thread]/[Channel] logging to the output, off by default
    HaltOnCriticalFailure = false,    -- see "Critical Services" above
})

Channel.Configure({
    DefaultRateLimit = 60,
    DefaultInvokeRateLimit = 30,
    DefaultMaxPayloadBytes = 65536,
    InvokeClientTimeout = 15,
    WaitTimeout = 15,                 -- how long the client waits for server-created folders/Remotes to appear
})
```

Call `Thread.Configure`/`Channel.Configure` once, early, before `Thread.Start()`. `Debug = true` is genuinely useful while developing — it prints every service registration, remote creation, and lifecycle step — but noisy in production, hence the `false` default.

## The Low-Level Channel API

For quick, one-off networking that doesn't belong to any particular service's `Client` table — this is the original string-keyed API, and it still works exactly as it did in the original v1.1.1 project:

```lua
-- Server
Channel.On("PlayerJumped", function(player)
    print(player.Name, "jumped")
end)

-- Client
Channel.FireServer("PlayerJumped")
```

| Function | Direction | Description |
|---|---|---|
| `Channel.On(name, callback, rateLimit?)` | both | Listens for a `RemoteEvent`. Server callback gets `(player, ...)`; client callback gets `(...)`. |
| `Channel.FireClient(name, player, ...)` | server → one client | |
| `Channel.FireAll(name, ...)` | server → all clients | |
| `Channel.FireServer(name, ...)` | client → server | |
| `Channel.SetFunction(name, callback, rateLimit?)` | both | Sets up a `RemoteFunction` handler. |
| `Channel.InvokeServer(name, ...)` | client → server | Yields for the return value. |
| `Channel.InvokeClient(name, player, ...)` | server → client | Yields, with a timeout (see above). |
| `Channel.Event(name)` / `Channel.Function(name)` | same-context only | Returns a raw `BindableEvent`/`BindableFunction`. Only useful for server↔server or client↔client communication — Bindables never cross the network boundary. |

Reach for the `Client` table approach first; use this low-level API when a full service `Client` entry feels like overkill for a single throwaway event.

## Promise — Complete Reference

`Promise.luau` is a small, self-contained A+-ish implementation. It exists mainly so `Thread.Start()`/`Thread.OnStart()` have something to return, but it's a fully general-purpose async primitive you can use anywhere.

### Instance methods (called on a promise you already have)

| Method | Description |
|---|---|
| `promise:andThen(onResolve?, onReject?)` | Standard chaining. Returns a new promise. |
| `promise:catch(onReject)` | Shorthand for `:andThen(nil, onReject)`. |
| `promise:finally(callback)` | Runs `callback()` regardless of outcome, then passes the original result/error through. |
| `promise:timeout(seconds, err?)` | Rejects if `promise` hasn't settled within `seconds`. Doesn't cancel the underlying work, just stops waiting for it. |
| `promise:await()` | Yields the current thread until settled; returns the value or `error()`s with the rejection reason. Only call this from a thread that's safe to yield (i.e. not directly in certain Roblox callback contexts that disallow yielding). |
| `promise:getState()` | Returns `"Pending"`, `"Resolved"`, `"Rejected"`, or `"Cancelled"`. |
| `promise:cancel(reason?)` | Cancels pending work, runs registered cleanup callbacks, and reports whether cancellation happened. |

### Static constructors

| Function | When to use it |
|---|---|
| `Promise.new(function(resolve, reject, onCancel) ... end)` | Wrap async work and optionally register cancellation cleanup. |
| `Promise.resolve(value)` / `Promise.reject(err)` | Build an already-settled promise. |
| `Promise.cancelled(reason?)` | Build a cancelled Promise. |
| `Promise.all({...})` | Every promise must succeed; one failure rejects the whole batch immediately. |
| `Promise.allSettled({...})` | Run several things, never reject — get a per-entry `{Status, Value}`/`{Status, Error}` report. Good for "start everything, tell me what failed." |
| `Promise.race({...})` | Settles with whichever promise finishes first (success or failure). |
| `Promise.some({...}, count)` | Resolves once `count` of the promises have resolved; rejects if that becomes mathematically impossible. |
| `Promise.delay(seconds)` | Resolves with no value after `seconds` — useful purely for chaining (`Promise.delay(1):andThen(...)`). |
| `Promise.retry(fn, attempts)` | Calls `fn()` (must return a promise) up to `attempts` times, stopping at the first success. |
| `Promise.fromEvent(signal, predicate?)` | Wraps any `RBXScriptSignal` (or a `Thread.Signal`) into a one-shot promise that resolves the next time it fires. Optional `predicate(...)` to filter which firings count. |
| `Promise.is(value)` | `true` if `value` is a Promise instance. |
| `Promise.isCancelledError(value)` | Distinguishes cancellation from ordinary rejection. |
| `Promise.setUnhandledRejectionHandler(fn?)` | Installs reporting for rejected Promises with no observer. Pass nil to restore warnings. |

### Common patterns

```lua
-- Retry a flaky DataStore call:
Promise.retry(function()
    return Promise.new(function(resolve, reject)
        local ok, result = pcall(dataStore.GetAsync, dataStore, "key")
        if ok then resolve(result) else reject(result) end
    end)
end, 5):andThen(print):catch(warn)

-- Don't let a slow operation hang forever:
someSlowPromise:timeout(5):catch(warn)

-- Wait for the next CharacterAdded, as a promise instead of a callback:
Promise.fromEvent(player.CharacterAdded):andThen(function(character)
    print(character.Name, "spawned")
end)
```

## Util Modules — Complete Reference

Independent, requirable standalone from `Packages/Util/`, or via `Thread.Signal`/`Thread.Trove`/etc. after requiring `Thread`. None of them touch networking — they're general-purpose Lua/Roblox utilities, and behave identically on the server and the client.

### `Signal`

A fast, pure-Luau event class, independent of `BindableEvent`. Use this for in-process pub/sub between your own modules (server-only or client-only — it never crosses the network) — it's faster than `BindableEvent` and, unlike a Bindable, can carry any Lua value (functions, tables) as an argument.

```lua
local mySignal = Thread.Signal.new()
local connection = mySignal:Connect(function(msg) print(msg) end)
mySignal:Fire("hello")           -- "hello" printed
mySignal:Once(function() ... end) -- fires at most once, then auto-disconnects
mySignal:Wait()                   -- yields the current thread until the next Fire
mySignal:GetConnections()         -- array of every active connection
connection.Connected              -- true, until :Disconnect()/:Destroy() is called on it
connection:Disconnect()           -- connection:Destroy() is an identical alias
mySignal:DisconnectAll()
mySignal:Destroy()                -- disconnects everything, incl. any wrapped RBXScriptSignal
Thread.Signal.Wrap(someRBXScriptSignal) -- adapts an engine signal to this same API
Thread.Signal.Is(mySignal)        -- true - checks if a value is one of these Signal objects
```

Internally this uses a pooled-coroutine linked-list design (the same well-known "GoodSignal" shape used across the Roblox ecosystem) so that firing a signal doesn't allocate a fresh coroutine per call — it's meant to be cheap enough to use liberally.

### `Trove`

A cleanup/janitor helper: track a bunch of "things that need cleaning up" and tear them all down with a single call, instead of manually writing out a dozen `:Destroy()`/`:Disconnect()` calls.

```lua
local trove = Thread.Trove.new()

trove:Add(someInstance)                              -- cleaned up via :Destroy()
trove:Connect(player.CharacterAdded, onCharacterAdded) -- shorthand for trove:Add(signal:Connect(fn))
trove:Add(function() print("custom cleanup") end)      -- cleaned up by calling it
trove:Add(someTable, "Cleanup")                        -- cleaned up via someTable:Cleanup() (custom method name)
trove:Clone(somePart)                                  -- clones + tracks the clone
trove:Construct(SomeClass, arg1, arg2)                  -- SomeClass.new(arg1, arg2), tracked

trove:Remove(someInstance)  -- stop tracking it, without cleaning it up
trove:Clean()               -- clean up everything tracked so far; trove stays reusable
trove:Destroy()             -- same as :Clean() — the trove is done

local sub = trove:Extend()  -- a nested Trove, auto-cleaned when the parent trove is
trove:AttachToInstance(someInstance) -- auto :Destroy() the trove once someInstance is removed from the game
```

`Trove` figures out the right cleanup method automatically based on the value's type (`Destroy` for Instances, `Disconnect` for connections, calling functions directly, `task.cancel` for threads) — pass an explicit method name as the second argument to `:Add` only when the default guess is wrong.

### `TableUtil`

Table helper functions filling gaps in Lua's standard library. Except where noted, these return a **new** table rather than mutating the input.

```lua
TableUtil.Copy(tbl, deep?)             -- shallow by default; deep = true copies recursively
TableUtil.Sync(src, template)          -- two-way: src ends up with EXACTLY template's keys (extras removed!)
TableUtil.Reconcile(src, template)     -- one-way: adds missing keys, never removes anything (safe for save data)
TableUtil.Lock(tbl)                    -- deep table.freeze, mutates in place

TableUtil.SwapRemove(arrayTbl, i)             -- O(1) removal, doesn't preserve order
TableUtil.SwapRemoveFirstValue(arrayTbl, v)
TableUtil.Reverse(arrayTbl)
TableUtil.Shuffle(arrayTbl, rng?)

TableUtil.Map(tbl, function(value, key) return newValue end)
TableUtil.Filter(tbl, function(value, key) return keepIt end)
TableUtil.Reduce(tbl, function(acc, value, key) return newAcc end, initial)
TableUtil.Find(tbl, function(value, key) return matches end)  -- returns value, key or nil, nil
TableUtil.Every(tbl, fn)  -- true if fn(v,k) is true for ALL entries
TableUtil.Some(tbl, fn)   -- true if fn(v,k) is true for ANY entry
TableUtil.Keys(tbl)
TableUtil.Values(tbl)
TableUtil.IsEmpty(tbl)
TableUtil.Length(tbl)     -- counts ALL keys (unlike #tbl, works for dictionaries too)
```

`Reconcile` is the one you want for player save data: old saved tables automatically gain new fields your template added, without losing data your template doesn't know about. `Sync` is stricter (two-way) and is meant for things like config tables where extra/stale keys genuinely should be removed.

`Map`/`Filter`/`Reduce`/`Find`/`Every`/`Some`/`Keys`/`Values` all work over dictionaries by default. `Filter` specifically switches to array behavior (preserving order, compacting indices) whenever `#tbl > 0` — if a table has both an array part and separate string keys, only the array part gets filtered. Keep arrays and dictionaries as separate tables if you need to filter both.

### `Option`

A Rust-style `Option<T>`, for making "this might not have a value" explicit instead of silently passing `nil` around.

```lua
local result = Thread.Option.Wrap(dataStore:GetAsync(key)) -- Some(value) or None, based on nil-ness

result:Match({
    Some = function(v) print("Got", v) end,
    None = function() print("Nothing stored") end,
})

result:IsSome() / result:IsNone()
result:Unwrap()                 -- errors if None — use when you're SURE it's Some
result:Expect("custom error")   -- errors with your message if None
result:UnwrapOr(defaultValue)
result:UnwrapOrElse(function() return computeDefault() end)
result:Contains(value)          -- true if Some AND equal to value

result:And(otherOption)         -- otherOption if Some, else None
result:AndThen(function(v) return Thread.Option.Wrap(...) end) -- chain another Option-returning step
result:Or(otherOption)          -- self if Some, else otherOption
result:OrElse(function() return Thread.Option.Wrap(...) end)

Thread.Option.Some(value)  -- errors if value is nil - use only when you already know it's non-nil
Thread.Option.Is(obj)      -- true if obj is an Option
Thread.Option.None         -- the shared "no value" singleton itself (not a function call) - Option.Wrap(nil) returns exactly this
```

Use `Option` where a stray `nil` could realistically slip through unnoticed (DataStore reads, optional config lookups). For an obvious, immediately-checked `nil` (`if x then ... end` right after getting `x`), plain Lua is clearer — don't wrap everything just because you can.

### `EnumList`

Defines a custom enum with named, comparable, immutable members — Luau has no built-in way to do this yourself.

```lua
local Direction = Thread.EnumList.new("Direction", { "North", "South", "East", "West" })

print(Direction.North.Name)   --> "North"
print(Direction.North.Value)  --> 1 (position in the list, 1-indexed)

Direction:BelongsTo(Direction.North)  --> true
Direction:GetEnumItems()              --> array of all 4 items
Direction:GetName()                   --> "Direction"
Direction:FromName("South")           --> Direction.South
Direction:FromValue(1)                --> Direction.North
```

Use this instead of raw strings whenever you have a fixed, known set of named states (game phases, directions, item rarities) — a typo in a raw string (`"Nort"`) fails silently; `Direction.Nort` fails immediately and loudly (nil-index).

Both the `EnumList` itself and every individual item (`Direction.North`, etc.) are deep-frozen with `table.freeze` at creation time — you can't add members after the fact or mutate an item's `Name`/`Value`, which is what makes `==` comparisons between items reliable.

### `MathUtil`

Small numeric helpers Roblox's own `math` library doesn't already provide (`math.clamp`/`math.round`/`math.sign`/`math.noise` etc. cover the rest — this module doesn't duplicate them).

```lua
MathUtil.Lerp(0, 10, 0.5)                   --> 5
MathUtil.MapRange(0.5, 0, 1, 0, 100)        --> 50
MathUtil.FuzzyEquals(0.1 + 0.2, 0.3, 1e-9)  --> true
```

`MapRange(value, inMin, inMax, outMin, outMax)` rescales `value` from the `inMin..inMax` range into `outMin..outMax` — useful for things like mapping a joystick's `-1..1` axis onto a `0..100` UI bar. Passing `inMin == inMax` divides by zero (Lua floats give `inf`/`nan`, not an error) — that's on the caller to avoid. `FuzzyEquals` is for comparing floats that accumulated rounding error and shouldn't be checked with `==`.

### `TimerUtil`

Debounce/throttle wrappers for rate-limiting how often a function runs.

```lua
local onClick = Thread.TimerUtil.Debounce(function()
    print("clicked")
end, 1)

button.MouseButton1Click:Connect(onClick) -- ignores clicks within 1s of the last one
```

`Debounce(fn, seconds)` runs `fn` immediately on the first call, then ignores every call for `seconds` afterward until the cooldown expires — the classic pattern for stopping a `Touched` event from firing twice. `Throttle(fn, seconds)` runs `fn` immediately too, but instead caps it to at most once per `seconds` — no trailing call is scheduled for calls that get dropped, so the last call in a burst may simply be lost rather than deferred. Both return a new wrapped function; they don't mutate `fn`.

## Server vs. Client Cheat Sheet

The single most important thing to internalize: **the server and every client each run their own separate instance of `Thread`'s internal state** (`Thread._Register`, its own start `Promise`, etc.) — they are different Lua VMs entirely. Nothing about a service you create on the server is automatically visible to `Thread.GetService` on the client, or vice versa. `Channel` is the only bridge between the two.

| I want to... | On the **server** | On the **client** |
|---|---|---|
| Define a service/controller | `Thread.CreateService({...})` | `Thread.CreateService({...})` (same call — informally called a "controller" here, but it's the identical API) |
| Expose something to clients | Give the service a `Client = {...}` table | — (nothing to expose *from* the client to *other clients*) |
| Get one of MY OWN registered services | `Thread.GetService("X")` | `Thread.GetService("X")` |
| Get a **server** service's `Client` API | — (it already has direct access) | `Channel.BuildClient("X")` — **never** `Thread.GetService`, that only searches the client's own local registry |
| Fire a signal | `self.Client.MySignal:Fire(player, ...)` / `:FireAll(...)` / `:FireExcept(p, ...)` | `proxy.MySignal:Fire(...)` (server infers the player automatically) |
| Read/set a property | `:Get()` / `:Set(v)` / `:SetFor(p, v)` / `:GetFor(p)` / `:ClearFor(p)` | `:Get()` / `:Observe(fn)` only |

A common mistake (and the exact error message you'll see if you hit it):

```
[Thread] No service named 'ArrestService' is registered
```

This means you called `Thread.GetService("ArrestService")` on the client, but `ArrestService` was only ever created on the **server**. Use `Channel.BuildClient("ArrestService")` instead — see the [Troubleshooting](#troubleshooting) section for more of these.

## Exported Luau Types

Every module is written under `--!strict` and exports its own types, so if your own code also uses `--!strict` (or just wants editor autocomplete), you can reference them directly off the required module:

```lua
local Thread = require(game:GetService("ReplicatedStorage").Packages.Thread)

-- Type a service definition table explicitly:
local def: Thread.ServiceDef = {
    Name = "MoneyService",
    Client = { ... },
}

local MoneyService = Thread.CreateService(def)
```

| Type | From | Shape |
|---|---|---|
| `Thread.ServiceDef` / `Thread.Service` | `Thread` | Includes the Client table, dependencies, middleware, remote policies, limits, and all three lifecycle hooks. |
| `Thread.RegisterResult` | `Thread` | One entry of what `Thread.Register(...)` returns: `{ Module: ModuleScript, Success: boolean, Result: any, Error: any }`. |
| `Thread.Middleware` | `Thread` (re-exported from `Channel`) | `{ Inbound: MiddlewareList?, Outbound: MiddlewareList? }`. |
| `Channel.MiddlewareFn` | `Channel` | `(player: Player?, args: {any}) -> boolean` — the shape a single middleware function must match. `player` is nil for broadcasts. |
| `Channel.WrapOptions` | `Channel` | Middleware, policies, rate limits, payload limits, and deferred readiness options. |
| `Channel.RemotePolicy` / `Channel.RemoteError` | `Channel` | Validation rules for one remote and the structured Method failure shape. |
| `Promise.Promise<T>` | `Promise` | The Promise type itself, if you want to type a function as returning one: `function fetchData(): Promise.Promise<string>`. |
| `Signal.Signal` / `Signal.Connection` | `Util/Signal` | The Util Signal's own types. |
| `Trove.Trackable` / `Trove.SignalLike` | `Util/Trove` | What kinds of values `Trove:Add`/`:Connect` accept. |
| `Option.Option<T>` / `Option.MatchTable<T>` | `Util/Option` | The Option type and the shape `:Match({...})` expects. |
| `EnumList.EnumList` / `EnumList.EnumItem` | `Util/EnumList` | The EnumList type and the shape of one of its items. |

You'll rarely need most of these explicitly — Luau infers types from the values you pass in most of the time — but they're there for the cases where you want to annotate a variable ahead of assigning it, or write a helper function that accepts/returns one of these.

## Generation, Formatting, and Testing

`thread.config.json` is the source for package metadata, the runtime version, docs badges, Wally metadata, the service manifest, and generated client types. Add service signatures under its `services` object, then regenerate:

```bash
python scripts/generate.py
python scripts/generate.py --check
```

`generated/ClientTypes.luau` gives tooling a standalone copy of the static service shapes. The generated runtime facade is available directly through `Thread.Clients`, so configured services do not require a manual cast:

```lua
local Thread = require(ReplicatedStorage.Packages.Thread)

local inventory = Thread.Clients.InventoryService()
local sameInventory = Thread.Clients.BuildClient("InventoryService")
```

Both variables above have the generated `InventoryService` contract. Services omitted from `thread.config.json` remain available through the dynamic `Thread.Channel.BuildClient` API. CI also checks that a release tag exactly matches `v<package.version>`.

Service definitions use this shape:

```json
{
  "services": {
    "InventoryService": {
      "methods": {
        "GetItems": {
          "arguments": [],
          "returns": ["{ Item }"]
        }
      },
      "signals": {
        "ItemAdded": ["item: Item"],
        "PositionChanged": {
          "arguments": ["position: Vector3"],
          "unreliable": true
        }
      },
      "properties": {
        "Capacity": "number"
      }
    }
  }
}
```

At server startup, configured services must be registered and their actual `Client` members must match the generated runtime manifest. This prevents generated types from silently lying about the remotes that exist. Services omitted from the config remain dynamic for backward compatibility.

Install the pinned toolchain with Rokit and run the static checks:

```bash
rokit install
stylua --check src Tests generated
selene src Tests generated
rojo build default.project.json --output build/ThreadTests.rbxlx
rojo build integration.project.json --output build/ThreadIntegration.rbxlx
```

A tiny, dependency-free test runner lives under `Tests/` (no TestEZ, no Wally — just `pcall` + `assert`).

1. Put the contents of `src/` under `ReplicatedStorage/Packages` and put `Tests/` under `ServerScriptService/Tests`.
2. Start a Play/Test session in Studio (so `RunService:IsServer()` evaluates as true — some tests are server-only), then paste into the Command Bar:
   ```lua
   require(game.ServerScriptService.Tests["Thread.spec"])
   ```
   (adjust the path to wherever you placed `Tests/`)
3. Read the Output window — `[PASS]`/`[FAIL]` per test case, with a summary line at the end.

The unit suite covers Promises, lifecycle ordering and failure propagation, server-side Channel behavior, Properties, validation, structured errors, and utilities. `Tests/Integration` is a real Play-mode server/client test. It calls `Channel.BuildClient`, checks method tuples and structured failures, round-trips a Signal, replicates a Property, and shuts down Thread.

```bash
rojo build integration.project.json --output build/ThreadIntegration.rbxlx
./scripts/run_studio_tests.ps1
```

The GitHub workflow always runs generation, formatting, linting, manifest, and Rojo build checks. Its Studio job requires a self-hosted Windows runner labeled `roblox-studio` and repository variable `RUN_ROBLOX_INTEGRATION=true`, because hosted runners do not include Roblox Studio.

## Troubleshooting

**`No service named 'X' is registered` (thrown by `Thread.GetService`)**
You're calling `Thread.GetService` for a service that isn't registered *on that side*. If `X` is a server-only service and you're on the client, use `Channel.BuildClient("X")` instead. If it's the same side, make sure the module was actually required (check `Thread.Register`'s folder path and its returned report for a `Success = false` entry).

**`'<Name>' (<Class>) does not exist after waiting <N>s` / `Service '<Name>' never became ready`**
The client is waiting for a service ready marker the server never created. Usually this means the service name is misspelled, the service has no `Client` table, or that service failed during server startup. `Channel.BuildClient` already waits for server readiness; the client's own `Thread.OnStart()` only tracks client-side controllers and does not represent server startup.

**`Thread.Register expects an Instance (folder)` / similar type-assert errors**
These are intentional `assert()`s catching a wrong argument type immediately, rather than failing mysteriously later. Read the message — it names exactly what was expected.

**A critical service's failure didn't crash my script**
That's the default, intentional behavior since v1.0.0's rewrite (previously it hard-`error()`ed). Handle it via `Thread.Start():catch(...)`, or opt back into the old behavior with `Thread.Configure({ HaltOnCriticalFailure = true })`.

**Rate limit warnings in the output (`Rate limit exceeded: ...`)**
A player is calling a Method/Signal faster than the configured limit (default 20-30/sec) — either legitimate rapid input (raise the limit for that specific service via `RateLimit`/`InvokeRateLimit`) or exploit/spam attempts (leave it, that's the protection working as intended).

**Duplicate service name error**
Two different `ModuleScript`s called `Thread.CreateService({ Name = "X" })` with the same name — service names must be unique per side. Rename one, or check you're not accidentally requiring the same module twice via two different registration folders.

## Full API Reference Tables

### `Thread`
| Function | Description |
|---|---|
| `Thread.CreateService(def)` | Registers a service, lifecycle hooks, networking rules, and dependencies. |
| `Thread.GetService(name)` | Returns a registered service (from this side's registry) or errors. |
| `Thread.GetServices()` | Returns a copy of the full service registry. |
| `Thread.Unregister(name)` | Removes a service before `Start()`. |
| `Thread.Register(folder, recursive?)` | Requires every `ModuleScript` under `folder`; returns `{ Module, Success, Result, Error }[]`. |
| `Thread.Start()` | Binds Client remotes, runs `ThreadInit` then `ThreadStart` in dependency order. Returns the start `Promise`. |
| `Thread.OnStart()` | Returns an independent observer `Promise` for startup, safe to call any time. |
| `Thread.Stop()` / `Thread.OnStop()` | Stops services in reverse dependency order and destroys networking state. |
| `Thread.GetServiceStatus(name)` | Returns the current lifecycle state of a registered service. |
| `Thread.Configure({ Debug, HaltOnCriticalFailure })` | Central configuration. |
| `Thread.CreateSignal()` / `Thread.CreateUnreliableSignal()` / `Thread.CreateProperty(v)` | Markers for use inside a service's `Client` table. |
| `Thread.Version` | Current version string. |
| `Thread.Metadata` / `Thread.GeneratedServiceManifest` | Generated package metadata and runtime service contracts. |
| `Thread.Clients` | Generated typed client builders for configured services. |
| `Thread.Channel` | Direct access to the `Channel` module. |
| `Thread.Signal` / `.Trove` / `.TableUtil` / `.Option` / `.EnumList` / `.MathUtil` / `.TimerUtil` | Direct access to the Util modules. |

### `Channel`
| Function | Description |
|---|---|
| `Channel.WrapService(name, clientTable, opts?)` | Server-only. Binds a `Client` table to real Remotes. Called automatically by `Thread.Start()` for services with a `Client` field. |
| `Channel.BuildClient(name, timeout?)` | Client-only. Returns a proxy for a wrapped service. |
| `Channel.GetServiceManifest(name)` | Returns a copy of the exact server-side remote manifest. |
| `Channel.DecodeResponse(value)` / `Channel.IsRemoteError(value)` | Decodes wrapped Method responses and identifies structured failures. |
| `Channel.Destroy(name)` | Removes every Remote created for a service. |
| `Channel.On/FireClient/FireAll/FireServer/SetFunction/InvokeServer/InvokeClient/Event/Function` | Low-level, string-keyed API (unchanged from v1.x). |
| `Channel.Configure({...})` | Bulk-set `Channel.Debug`, `Channel.DefaultRateLimit`, etc. |

### `Property` (returned in place of a `Thread.CreateProperty()` marker)
| Method | Where | Description |
|---|---|---|
| `:Get()` | both | Client: last received value. Server: the shared default. |
| `:Set(value)` | server | Sets the default and broadcasts to every client without an override. |
| `:SetFor(player, value)` | server | Sets a value visible only to `player`. |
| `:GetFor(player)` | server | Reads `player`'s override, or the default if none. |
| `:ClearFor(player)` | server | Removes `player`'s override. |
| `:Observe(fn)` | client | Calls `fn` immediately and on every change; returns a `{Disconnect}` handle. |
| `:Destroy()` | server | Disconnects the internal `PlayerRemoving` connection. Rarely called directly — `Channel.Destroy(serviceName)` handles teardown for you. |

### `Signal` (the service-scoped, Remote-backed version returned in `Client` tables)
| Method | Where | Description |
|---|---|---|
| `:Fire(...)` | server: `:Fire(player, ...)` to one client. client: `:Fire(...)` to the server. |
| `:FireAll(...)` | server | To every client. |
| `:FireExcept(player, ...)` | server | To every client except `player`. |
| `:Connect(fn)` | both | Server handler gets `(player, ...)`; client handler gets `(...)`. |
| `:Destroy()` | both | Disconnects/destroys the underlying Remote. |

Note: this is a different `Signal` class from the standalone `Util/Signal.luau` described above — same name, but one is Remote-backed (this one) and the other is pure in-process pub/sub. They're not interchangeable.

### `Promise`
See [Promise — Complete Reference](#promise--complete-reference) above for the full, annotated list.

### Util modules (`Packages/Util/`, also on `Thread.*`)
See [Util Modules — Complete Reference](#util-modules--complete-reference) above for the full, annotated list.

See [CHANGELOG.md](CHANGELOG.md) for the version history.
