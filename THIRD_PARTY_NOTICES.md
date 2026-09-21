# Third-party notices

This driver is original work, licensed under Apache-2.0. It was written with
reference to two SmartThings projects, and this file records exactly what came
from where — file by file, so provenance is not left to inference.

Neither upstream project ships a `NOTICE` file, so Apache-2.0 §4(d) imposes no
notice to propagate. This file exists because §4(b) and §4(c) are about
retaining attribution and marking changes, and a reader deserves to know which
lines are whose.

---

## Upstream projects referenced

**SmartThingsCommunity/SmartThingsPublic** — the legacy Groovy device handler.
<https://github.com/SmartThingsCommunity/SmartThingsPublic>

The repository carries no top-level `LICENSE` file. The specific file
consulted carries its own header: `Copyright 2015 SmartThings`, licensed under
the Apache License, Version 2.0. That per-file grant is the basis on which it
is used here.

- `devicetypes/smartthings/aeon-smartstrip.src/aeon-smartstrip.groovy`

**SmartThingsCommunity/SmartThingsEdgeDrivers** — the current Edge driver set.
Apache-2.0. <https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers>

- `drivers/SmartThings/zwave-switch/src/configurations.lua`
- `drivers/SmartThings/zwave-switch/src/aeon-smart-strip/init.lua`

---

## What was taken, file by file

| This file | Relationship to upstream |
|---|---|
| `src/endpoints.lua` | **Independent implementation of a documented fact.** The dual endpoint mapping is a property of the hardware. Two short Groovy excerpts appear **in comments**, reformatted and truncated, attributed inline with their copyright and licence. No upstream code is executed or translated. |
| `src/configuration.lua` | **Factual data, independently structured.** The fifteen parameter numbers, sizes and values match `configurations.lua`'s `AEON_SMART_STRIP` because they are the values this hardware requires. Numeric device-configuration values are facts about a device, not expression. The surrounding Lua is original. |
| `src/handlers.lua` | **Original.** Written against the published SmartThings Lua API. Upstream's `aeon-smart-strip` subdriver was read to understand what it does and does *not* request; the behaviour here deliberately differs. |
| `src/driver_template.lua`, `src/init.lua`, `src/preferences.lua` | **Original.** Conventional driver assembly against the documented API. |
| `profiles/`, `config.yml`, `fingerprints.yml` | **Original.** Packaging metadata. The Z-Wave fingerprint `0086/0003/000B` is a public product identifier. |
| `test/` | **Original.** No SmartThings test harness is used. |

**No file in this repository is a copy, translation, or modification of
upstream source code.** Where upstream expression appears at all it is a short
quotation inside a comment, marked as such, for the purpose of documenting why
the hardware behaves as it does.

---

## Trademarks

Aeon Labs and Aeotec are trademarks of Aeotec. SmartThings is a trademark of
Samsung Electronics. Z-Wave is a trademark of Silicon Labs and the Z-Wave
Alliance. These names are used descriptively, to identify the device, platform
and protocol this driver works with.

**This is an unofficial community driver. It is not affiliated with, endorsed
by, or certified by Aeotec, Samsung SmartThings, or the Z-Wave Alliance.** No
vendor logos or certification marks are used.
