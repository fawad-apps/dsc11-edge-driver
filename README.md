# Aeon DSC11 Smart Strip — SmartThings Edge driver

A SmartThings Edge driver for the **Aeon Labs / Aeotec DSC11 Smart Strip**
(also sold as the Smart Energy Strip, Z-Wave fingerprint `0086/0003/000B`).

Each of the strip's four switchable outlets gets its own switch, **power and
energy readings**, and its own energy-meter reset — so you can tell what one
appliance on the strip is drawing, rather than only the strip as a whole.

> **Status:** run on real hardware and working — all seven
> components populate, including the two always-on sockets no driver has shown
> before. Covered by 512 automated tests. Some things remain unverified; see
> [Status and limitations](#status-and-limitations) before installing.

> **Safety.** This driver switches mains-voltage outlets. Use the strip only
> within its rated load. Do not rely on it for life-safety, medical, or
> unattended hazardous loads: switching is not guaranteed during hub, driver,
> network, or Z-Wave failures, and an outlet may be left in either state.
> Provided as-is, without warranty — see [LICENCE](#licence). Installation and
> use are at your own risk.

> **Unofficial.** This is a community driver. It is not affiliated with,
> endorsed by, or certified by Aeotec, Samsung SmartThings, or the Z-Wave
> Alliance. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

## Before you start: check which socket your load is in

**The DSC11 has six sockets, and only four of them are Z-Wave controllable.**
The remaining two are always-on passthroughs. **Nothing can switch them** — not
this driver, not the stock one, not any driver that could be written.

**But they can be metered, and this driver meters them.** That was an open
question until it was checked against hardware: the strip reports all six
sockets, and the two always-on ones appear here as `alwaysOn1` and
`alwaysOn2`. On the unit it was established against, one of them carried a
standing load larger than every switchable outlet combined — and no driver had
ever shown it.

So if the appliance you care about is on an always-on socket you still cannot
switch it, and moving its plug is still the fix. What changed is that you can
now *see* it, and decide whether it is worth moving.

---

## What you get

| Component | Switch | Power (W) | Energy (kWh) | Energy reset |
|---|:-:|:-:|:-:|:-:|
| The strip (`main`) | ✅ | ✅ | ✅ | ✅ resets all |
| Outlets 1–4 (`switch1`–`switch4`) | ✅ | ✅ | ✅ | ✅ per outlet |
| Always-on sockets (`alwaysOn1`, `alwaysOn2`) | ✗ can't be | ✅ | ✅ | — |

Seven components, not five. The always-on pair carry no switch, because
nothing can switch them — offering a control that cannot work would be worse
than offering none.

- **Per-outlet power.** The stock driver leaves per-outlet wattage permanently
  empty (see [Why this driver exists](#why-this-driver-exists)). This one polls
  it and keeps it fresh.
- **Per-outlet energy reset, with a button that actually appears.** Clear one
  socket's kWh total without touching the others — useful when you move an
  appliance and want a clean baseline. There is a **"Reset energy"** button on
  every component.
  
  It is a custom capability, and it exists for a reason worth knowing: the
  standard `energyMeter` capability already declares its own reset button, the
  platform serves it unconditionally, and **the app does not draw it**. The
  app substitutes its own energy card — the one with the history graph — for
  `powerMeter`/`energyMeter`, and the generic controls belonging to them go
  with it. Verified against the live device presentation. The standard command
  still works from automations and the API; the custom button is simply one
  the app renders. Both call the same handler.

  The card also shows **when that meter was last reset**, because a button
  that wipes a lifetime register and gives no feedback is a bad button — the
  kWh figure only changes seconds later, once the strip answers, so without it
  the tap looks like it did nothing.
- **SmartThings Energy.** `powerConsumptionReport` is what the platform's
  energy screen reads; `energyMeter` alone never reaches it. Emitted per
  component, including each outlet — though whether the platform *displays*
  sub-component consumption, or sums it, has not been verified. See
  [Status and limitations](#status-and-limitations).
- **Refresh that covers everything.** Refreshing queries the strip *and* all
  six sockets, for both power and energy — from the app, from an automation,
  from an individual outlet, or from the built-in fallback poll.
- **One command at a time, and yours first.** Every sequence in the driver
  goes through a single queue drained one command per second, so a switch, a
  reset, a settings change and the poll can never talk over each other. What
  you do in the app jumps ahead of background work, so tapping a switch during
  a poll still acts immediately rather than waiting for the poll to finish.
- **A fallback poll.** Per-outlet freshness otherwise depends entirely on the
  strip's unsolicited reports. If those quietly stop, a ten-minute poll
  backfills rather than letting an outlet sit at a stale figure forever.
- **Adjustable reporting.** Report intervals and change thresholds are device
  preferences, settable in the app — no code change, and no silent revert the
  next time the driver is reinstalled.
- **Self-configuring, and self-checking.** Sets the strip's reporting
  parameters on install, then reads them back — and only records the device as
  configured once the strip confirms every one. A strip that was asleep or out
  of range during the install is retried on the next driver start instead of
  being written off as done.
- **Self-describing.** On every configure it asks the strip which meter scales
  it supports and which version of the meter command class it speaks, and logs
  the answers. See [Checking what your strip supports](#checking-what-your-strip-supports).

## Requirements

- A SmartThings hub that supports Edge drivers (v2, v3, Aeotec, or a Station).
- The [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli).
- A DSC11 already paired to your hub.

> ⚠️ **If you are installing this yourself, read this first.** The profile
> declares a custom capability for the reset button
> (`autumnpepper05038.energyreset`). Custom capabilities belong to the account
> that created them, and this one has not been published, so **your hub may
> not be able to resolve it** — which can stop the profile loading at all.
>
> If packaging fails, or components do not appear, remove the four
> `autumnpepper05038.energyreset` entries from
> `profiles/dsc11-smart-strip.yml` and the `RESET_ENERGY` block from
> `src/driver_template.lua`. Everything else works unchanged; you lose only
> the in-app reset button, and the reset itself stays reachable from
> automations and the API — see [Per-outlet energy reset](#what-you-get).

## Installing

```sh
smartthings edge:drivers:package .    # build and upload
smartthings edge:channels:assign      # assign it to your channel
smartthings edge:channels:enroll      # enrol your hub (first time only)
smartthings edge:drivers:install      # install it to the hub
smartthings edge:drivers:switch       # point your strip at this driver
```

If you don't have a channel yet, `smartthings edge:channels:create` makes one.
SmartThings' [shared-channel guide](https://developer.smartthings.com/docs/devices/hub-connected/driver-channels)
covers the concepts.

`drivers:switch` swaps the driver on your existing device **in place**. The
fingerprint is unchanged, so you should not need to exclude and re-pair the
strip. It's still worth noting which automations reference the device first.

To watch what the strip and driver are actually saying to each other:

```sh
smartthings edge:drivers:logcat
```

## Using it

The strip appears as seven components: the strip itself, `switch1` through
`switch4` for the switchable outlets, and `alwaysOn1` / `alwaysOn2` for the two
passthrough sockets — metered but not switchable.

**Which outlet is which?** `switch1`–`switch4` are the strip's Z-Wave switch
endpoints 1–4. Which physical socket each one drives has not been confirmed, so
the components ship unlabelled.

You do not need to move any plugs to find out. Switch on something already
plugged in, refresh, and watch which component's wattage moves. That component
is the one it is on; rename it in the SmartThings app. A load switching on
moves exactly one outlet's reading and leaves the others at zero, which names
that outlet in a single step.

It's worth doing. Get it wrong and every reading afterwards is attributed to
the wrong appliance.

Switching the strip itself switches all four outlets. The driver then asks each
outlet individually what it actually did, rather than assuming they all
followed.

The reverse holds too: the strip's own switch follows its outlets. Turn all
four off one at a time and the strip reads off; turn any one back on and it
reads on. It is derived only once all four outlets have reported at least once
— a strip state guessed from a partial picture would be worse than none.

### Adjusting how often it reports

Four settings are exposed in the app, under the device's settings screen:

| Setting | Parameter | Default |
|---|:-:|:-:|
| Per-outlet report interval | 112 | 90 s |
| Strip report interval | 111 | 900 s |
| Report threshold (watts) | 5, 8, 9, 10, 11 | 5 |
| Report threshold (percent) | 12, 15, 16, 17, 18 | 50 |

The two thresholds each drive their whole group rather than one outlet apiece.
The strip has five of each for four outlets plus the strip, and which parameter
governs which outlet has not been established — naming one "Outlet 1" would be
a guess, and this codebase has twice declined to make that kind of guess. Once
a known load has been measured in each socket, splitting them is a small
change.

Changing a setting sends it to the strip and then reads it back, the same way
a fresh install does. Reinstalling or switching drivers will not revert it.

## Checking what your strip supports

Every configure ends by asking the strip what it can do and logging the
answers. Run `smartthings edge:drivers:logcat` and then switch drivers or
reinstall — changing a setting is not enough, because that path only sends the
parameters it changed.

On one DSC11-ZWUS:

```
device speaks METER v2
meter supports: kWh, W (scale_supported = 0x05, meter_type = 1, resettable = true)
```

What the answers mean:

- **`W` is supported.** The scale this driver exists to request. If it were
  absent the driver would warn, and per-outlet power could not work on that
  unit under any driver.
- **`kVAh` is NOT supported** — bit 1 of the mask is clear. This is worth
  dwelling on, because `kVAh` is precisely what the stock `zwave-switch`
  subdriver asks the outlet endpoints for. It is not merely failing to ask for
  watts; it is asking for a scale this hardware does not have.
- **`V` and `A` are not supported either** (bits 4 and 5 clear), so
  `voltageMeasurement` and `currentMeasurement` are off the table. That
  question is closed rather than pending.
- **`resettable = true`.** Per-outlet energy reset was implemented because
  SmartThings' original handler shipped it. This is the strip confirming it.
- **`METER v2`, not v1.** `Meter:Get`'s scale argument is a v2 concept, so the
  scale-specific requests this driver depends on are valid. The driver warns
  if it ever sees v1.

Your unit may differ; the driver logs whatever yours says.

### The always-on sockets

**Answered: the strip meters all six sockets.** This was an open question
through two reviews, and the way it was settled is worth recording, because
the answer turned out to explain the whole endpoint layout.

It started as an arithmetic gap. With everything on the strip idle, the
whole-strip reading was far higher than the four switchable outlets summed to
— a large, steady difference that no component could account for.

A load on one outlet was then switched on, nothing else touched. Its draw
landed entirely on its own outlet — which is also the easiest way to work out
which outlet is which — and **the unaccounted difference did not move.** Not
an artefact, not the load being switched. A steady draw through sockets
nothing could see.

That suggested a layout which *explains* the meter offset rather than merely
accommodating it: the strip meters all six sockets on meter endpoints 1–6, the
two always-on ones first, so the four switchable sockets land on 3–6 — which
are switch endpoints 1–4. The `+2` is then simply *skip the two always-on
sockets*.

Asking meter channels 1 and 2 directly confirmed it. Both answered, one
carrying the missing load and the other near zero, and with all six sockets
read the arithmetic closes:

```
  switchable outlets 1-4   (meter endpoints 3-6)  ┐
  always-on sockets  A,B   (meter endpoints 1-2)  ┘ sum to the strip total
```

On the unit this was established against, the six readings summed to the
strip's own whole-device total to within a fraction of a percent — and the
energy registers summed to it exactly. An independent check the device
computes for itself, which a wrong mapping would fail.

So `alwaysOn1` and `alwaysOn2` are now real components, carrying power and
energy but no switch. The largest consumer on that strip turned out to be the
one component no driver had ever shown.

**What this means for the endpoint map.** `METER_OFFSET` is no longer a quirk
recovered from a 2016 handler; it is the number of always-on sockets that come
first, and `endpoints.lua` now derives it from `ALWAYS_ON_COUNT` so the two
cannot drift apart.

## Why this driver exists

SmartThings' stock `zwave-switch` driver already handles this strip, and its
per-outlet **energy** (kWh) works. Per-outlet **power** (W) does not, and the
reason is visible in the source: the stock subdriver asks the outlet endpoints
for `kWh` and `kVAh`, and never asks for `WATTS`. Per-outlet wattage can
therefore only ever appear if the strip volunteers it — no refresh will produce
it.

The original Groovy device handler that SmartThings shipped for this strip did
ask for watts per outlet. The migration to Edge dropped it.

This driver also adds two things the stock subdriver has no code for at all:
per-outlet energy reset, and a read-back that confirms the strip's reporting
parameters were actually applied.

If you'd rather not run a third-party driver, the watts gap is a small,
self-contained fix to the stock driver, and contributing it upstream would be a
better outcome than anyone maintaining a fork. See
[Contributing](#contributing).

## How it works

One detail explains most of this codebase, and it will bite anyone who changes
it without knowing:

> **The DSC11 addresses the same outlet with two different endpoint numbers,
> depending on the command class.**

| Outlet | Switch endpoint | Meter endpoint |
|:-:|:-:|:-:|
| 1 | 1 | 3 |
| 2 | 2 | 4 |
| 3 | 3 | 5 |
| 4 | 4 | 6 |

**And the reason is that the meter counts all six sockets, always-on first:**

| Meter endpoint | Socket | Switchable? |
|:-:|---|:-:|
| 1 | always-on A | ✗ |
| 2 | always-on B | ✗ |
| 3 | outlet 1 | ✅ (switch endpoint 1) |
| 4 | outlet 2 | ✅ (switch endpoint 2) |
| 5 | outlet 3 | ✅ (switch endpoint 3) |
| 6 | outlet 4 | ✅ (switch endpoint 4) |

So the `+2` is not arbitrary: it is the count of always-on sockets that come
before the switchable ones. `endpoints.lua` derives `METER_OFFSET` from
`ALWAYS_ON_COUNT` for exactly that reason, and a test asserts they agree.

This is the hardware's own behaviour, not a bug or a workaround. SmartThings'
original handler for the strip applied the offset explicitly, and only for
meter traffic:

```groovy
if (cmd.commandClassId == 0x32) {          // COMMAND_CLASS_METER
    // Metered outlets are numbered differently than switches
    if (endpoint < 0x80) { endpoint += 2 }
```

Endpoints 3 and 4 are therefore ambiguous: they are the *switch* endpoints for
outlets 3 and 4 and the *meter* endpoints for outlets 1 and 2. Only the command
class distinguishes them.

Three consequences shape the code:

1. **A single component-to-endpoint map cannot describe this device.** The maps
   registered with the platform carry the *switch* convention only.
2. **Meter traffic is handled by hand** — meter commands are addressed
   explicitly, and meter reports are routed explicitly.
3. **The platform's default handlers are not used.** The default refresh and
   the default power and energy report handlers all route meter traffic through
   that single map, which would quietly report outlet 1's power as outlet 3's.

`src/endpoints.lua` documents the full derivation, with sources.

Two smaller decisions worth knowing about:

- **Commands are staggered, roughly a second apart, never sent in a burst.**
  This is 2012-era hardware on a non-secure Z-Wave link, and both the original
  handler and other SmartThings multi-outlet drivers carry workarounds for
  reading it too quickly.
- **A strip-level switch report is not applied to the four outlets.** It says
  nothing about their individual states, and treating it as though it does is
  what makes all four outlets appear to work while per-outlet reporting is in
  fact dead.

## Layout

```
config.yml                      driver name, package key, permissions
fingerprints.yml                0086/0003/000B -> dsc11-smart-strip
profiles/dsc11-smart-strip.yml  components, capabilities, app settings
src/endpoints.lua               the dual endpoint mapping, and why it exists
src/configuration.lua           the strip's 15 device parameters
src/preferences.lua             which of them are settable in the app
src/handlers.lua                Z-Wave and capability handlers
src/driver_template.lua         which handler is registered against what
src/init.lua                    starts the driver, nothing else
test/                           test suite
```

## Development

The tests are plain Lua with no SmartThings test harness and no hub, because
the things most likely to be wrong here — endpoint arithmetic, and which meter
scale gets requested — need no hardware to check. Any Lua 5.3 or newer
interpreter will run them:

```sh
./test/run.sh                    # everything
lua test/test_endpoints.lua      # the endpoint mapping alone
```

**512 assertions**, in four files:

| File | Covers |
|---|---|
| `test_endpoints.lua` | both endpoint mappings and their overlap |
| `test_preferences.lua` | which parameters are tunable, and the effective value each one resolves to |
| `test_template.lua` | which handler is registered against which command |
| `test_handlers.lua` | what the real handlers put on the wire |

`test_handlers.lua` drives the handlers against stubbed platform libraries and
asserts what would reach the strip: that a refresh asks the meter endpoints for
watts, that a meter report from endpoint 3 is credited to outlet 1, that
resetting outlet 1 resets outlet 1, that configuration can't run twice
concurrently, that commands are staggered rather than bursted, and that energy
reaches SmartThings Energy in watt-hours over windows that don't overlap.

`test_template.lua` exists because every other test calls a handler directly,
so all of them pass even when a handler is wired to the wrong command. Swap two
registrations and the behavioural suite stays green while the driver routes
meter readings into the configuration logger. `src/init.lua` ends with a call
that blocks, so the registrations live in `src/driver_template.lua` where a
test can read them without starting anything.

The suite is mutation-tested. Fifty-three deliberate breakages — bursting
every sequence, misregistering a handler, reverting preferences on a driver
switch, reporting energy in the wrong unit, letting an energy reset produce a
negative delta, reading the scale bitmask as a plain number, skipping a
read-back, leaking a timer, treating a configuration as confirmed when it was
only sent, carrying confirmations across configures, deriving the strip's
state from a partial picture, reinstating the redundant `added` refresh,
letting two refreshes interleave, dropping a queued refresh instead of
honouring it, swapping the two always-on sockets, routing their readings to
outlets, decoupling the meter offset from the always-on count, letting a user command
wait behind background polling, and discarding the first consumption window —
were each confirmed to make the suite fail. Four of them survived their first
pass; the gaps those exposed are closed and listed in the history.

## Status and limitations

**Verified on hardware**, on one DSC11-ZWUS:

- **Per-outlet power populates.** The defect this driver exists to fix is
  fixed: outlets report their own wattage, where the stock driver leaves that
  field permanently empty.
- Meter traffic addressed to endpoints 3–6 came back on channels 3–6 and was
  credited to outlets 1–4 — the dual endpoint mapping is correct in practice,
  not just in the sources.
- All fifteen configuration parameters were accepted and all four read-backs
  matched, producing `configuration confirmed by the device`.
- `init` and `driverSwitched` both fired, 0.2 s apart, and the in-flight guard
  caught the duplicate — the exact case it was written for.
- The strip reports `METER v2` and supports `kWh` and `W`, and reports itself
  resettable.
- **`powerConsumptionReport` is emitted on every component**, in watt-hours,
  with each window opening where the last one closed — and the gate observed
  firing at the interval it is set to.
- **The fallback poll fired at exactly its interval** after `init`, and
  refreshed every reading.
- Unsolicited per-outlet reports arrived between polls, so parameters 102 and
  112 are doing what they were set for.
- Switching an appliance on moved only its own outlet, confirming the meter
  endpoints are attributed to the right components under load and not merely
  at idle.
- **All seven components populate**, always-on sockets included, with zero
  warnings logged. The six socket readings sum to the strip's own whole-device
  total, so the endpoint map is not merely self-consistent — it reconciles
  against an independent measurement the device makes itself.

**Verified by test:** the endpoint mapping and configuration parameters are
each corroborated by two independent SmartThings sources; all Lua parses; the
packaging metadata parses and is internally consistent; 512 assertions pass
under a real Lua interpreter and fail under deliberate mutation.

**Still unverified:**

- Per-outlet energy *reset* has not been exercised, though the strip now
  reports `resettable = true`, which is better evidence than it had.
- The physical socket each component drives has not been confirmed — see
  [Using it](#using-it).
- The always-on sockets **were** the open question and are now answered — see
  [The always-on sockets](#the-always-on-sockets). What remains unverified is
  which *physical* socket `alwaysOn1` and `alwaysOn2` correspond to, same as
  for the switchable four.
- The strip's switch state is derived from the four outlets, so it stays
  correct as they change — but only after all four have reported at least
  once, which in practice means after the first refresh.
- **Parameter 4 is undocumented, and was wrongly suspected.** SmartThings
  ships it as 1 in both the legacy handler and the Edge driver, neither says
  what it does, and this driver inherited it on that authority. It was
  suspected of resetting accumulated energy — the strip reported near-zero
  lifetime energy one evening and its true totals only after being unplugged.
  **Tested and cleared:** with known non-zero values in the registers, a full
  configure was forced and every one came back unchanged. Parameter 4 does not
  wipe energy. What did cause that earlier behaviour is still unknown —
  recorded rather than guessed at twice. See `src/configuration.lua`.
- The preference ranges are sane rather than verified: the DSC11 manual has
  not been checked for the actual permitted values of parameters 5/8–12/15–18
  and 111/112. A value the strip rejects will show up in the read-back as
  having not taken.
- `powerConsumptionReport` windows and the fallback poll are driven by the
  hub's clock and timer, neither of which the test suite can exercise for
  real — the tests control time rather than pass it.
- **Sub-component `powerConsumptionReport` is emitted, but what the platform
  does with it is unproven.** The reports themselves are confirmed on
  hardware, on all seven components. What has *not* been observed is the other
  end: the platform libraries carry no default handler for this capability,
  and no SmartThings driver was found emitting it on anything but `main`.
  Either SmartThings Energy ignores sub-component reports, making the
  per-outlet emission harmless and useless, or it sums every component, in
  which case the strip is double-counted because `main` already reports the
  whole-strip total. If the energy figures look roughly doubled, that is the
  cause — emit on `main` only.

If you run this on real hardware, an issue saying what happened — working or
not — would be genuinely useful.

## Contributing

Issues and pull requests are welcome, particularly hardware reports.

If you want to improve the situation for everyone rather than just this repo,
the highest-value change is upstream: add a watts-scale meter request to the
`aeon-smart-strip` subdriver in
[SmartThingsEdgeDrivers](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers).
Note that the existing upstream tests correctly assert the endpoint 3–6
addressing described above — a fix there should change the meter scale, not the
endpoint mapping.

## Credits

The endpoint mapping and the device configuration parameters were both
recovered from SmartThings' own work on this device:

- the legacy Groovy device handler in **SmartThingsPublic**. That repository
  has no top-level `LICENSE`, but the file itself carries
  `Copyright 2015 SmartThings` under the Apache License, Version 2.0, and that
  per-file grant is the basis on which it is used here.
- the `zwave-switch` Edge driver in **SmartThingsEdgeDrivers**, Apache-2.0.

No file here is a copy, translation, or modification of upstream source. Where
upstream expression appears at all it is a short quotation inside a comment,
marked as such and attributed inline. The full file-by-file provenance is in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Licence

Apache-2.0. See [LICENSE](LICENSE).
