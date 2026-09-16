# Thread

Thread is a dependency-aware service framework and networking layer for Roblox. It provides structured services, typed client contracts, predictable startup and shutdown, middleware, validation, rate limiting, Promises, and small utility modules without runtime dependencies.

[Documentation](https://realthonik.github.io/Thread/) · [Installation](https://realthonik.github.io/Thread/installation.html) · [API reference](https://realthonik.github.io/Thread/reference.html) · [Releases](https://github.com/realthonik/Thread/releases) · [Changelog](CHANGELOG.md)

## Why Thread

- Services initialize and start in dependency order.
- Client methods, Signals, and Properties are declared beside server behavior.
- Remote payloads can be validated, limited, and transformed through middleware.
- Service readiness is published only after a successful lifecycle.
- Startup, shutdown, retries, timeouts, and cancellation use a built-in Promise implementation.
- The runtime is pure Luau and has no third-party dependencies.

## Install

### Roblox Studio asset

1. Open the [`v1.2.2` release](https://github.com/realthonik/Thread/releases/tag/v1.2.2).
2. Download `Thread.v1.2.2.rbxm`.
3. Drag it into Roblox Studio.
4. Move the `Thread` ModuleScript to `ReplicatedStorage.Packages`.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Thread = require(ReplicatedStorage.Packages.Thread)
```

### Rojo

Map `src` as the `Thread` ModuleScript:

```json
{
  "ReplicatedStorage": {
    "Packages": {
      "$className": "Folder",
      "Thread": {
        "$path": "src"
      }
    }
  }
}
```

### Wally

The repository includes a Wally manifest for `realthonik/thread@1.2.2`. Check the [Wally package page](https://wally.run/package/realthonik/thread) before installing because corrected versions must be published separately and Wally versions are immutable. Use the Studio asset when `1.2.2` is not listed.

```toml
[dependencies]
Thread = "realthonik/thread@1.2.2"
```

## Quick start

Define a server service:

```lua
-- ServerScriptService/Services/MoneyService.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Thread = require(ReplicatedStorage.Packages.Thread)

local balances = {}

local MoneyService = Thread.CreateService({
    Name = "MoneyService",
    Client = {
        GetMoney = function(self, player)
            return self.Server:GetMoney(player)
        end,
        MoneyChanged = Thread.CreateSignal(),
    },
})

function MoneyService:GetMoney(player)
    return balances[player] or 0
end

function MoneyService:GiveMoney(player, amount)
    balances[player] = self:GetMoney(player) + amount
    self.Client.MoneyChanged:Fire(player, balances[player])
end

return MoneyService
```

Register and start services on the server:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Thread = require(ReplicatedStorage.Packages.Thread)

Thread.Register(ServerScriptService.Services)
Thread.Start():catch(warn)
```

Build the matching client proxy:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Thread = require(ReplicatedStorage.Packages.Thread)

local MoneyService = Thread.Channel.BuildClient("MoneyService")

print(MoneyService:GetMoney())
MoneyService.MoneyChanged:Connect(function(balance)
    print("New balance:", balance)
end)
```

## Lifecycle

Thread performs startup in this order:

1. Register service modules.
2. Validate and topologically sort dependencies.
3. Bind and validate server remotes.
4. Await `ThreadInit` for each healthy service.
5. Await `ThreadStart` for each healthy service.
6. Publish service readiness and resolve `Thread.Start()` and `Thread.OnStart()`.

`Thread.Stop()` awaits `ThreadStop` in reverse dependency order. Failed services and their dependents are skipped. A failed critical service rejects startup.

See the [graphical execution model](https://realthonik.github.io/Thread/services.html#the-lifecycle) for the complete flow.

## Project layout

```text
src/                     Runtime package
Tests/                   Unit and Studio integration tests
docs/                    Documentation website
generated/               Standalone generated contracts for tooling
scripts/generate.py      Metadata and type generator
thread.config.json       Package and generation source of truth
default.project.json     Release asset build
dev.project.json         Unit-test place build
integration.project.json Studio integration place build
```

Generated files under `src/Generated/` are part of the runtime. Do not edit generated files directly. Change `thread.config.json`, then regenerate them.

## Development

Install the pinned tools:

```powershell
rokit install
```

Regenerate and verify package metadata:

```powershell
python scripts/generate.py
python scripts/generate.py --check
python scripts/test_generate.py
```

Run static checks and build the release asset:

```powershell
stylua --check src Tests generated
selene src Tests generated
wally manifest-to-json
rojo build default.project.json --output build/Thread.rbxm
rojo build dev.project.json --output build/ThreadTests.rbxlx
rojo build integration.project.json --output build/ThreadIntegration.rbxlx
```

The optional Studio integration job uses:

```powershell
./scripts/run_studio_tests.ps1
```

## Documentation

The website contains the detailed guides that previously lived in this README:

- [Services and lifecycle](https://realthonik.github.io/Thread/services.html)
- [Client tables and networking](https://realthonik.github.io/Thread/client-table.html)
- [Dependencies, middleware, and failure](https://realthonik.github.io/Thread/dependencies-middleware.html)
- [Configuration and low-level Channel API](https://realthonik.github.io/Thread/configuration.html)
- [Promise](https://realthonik.github.io/Thread/promise.html)
- [Utility modules](https://realthonik.github.io/Thread/utilities.html)
- [Cheat sheet and API tables](https://realthonik.github.io/Thread/reference.html)

## License

Thread is licensed under the [Mozilla Public License 2.0](LICENSE).
