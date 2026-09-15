# Compatibility and protocol boundary

This document describes the narrow boundary implemented by this project. It is
not a vendor protocol specification and is not intended as a compatibility
claim for any other device.

## Tested interfaces

| Mode | USB vendor ID | USB product ID |
| --- | ---: | ---: |
| MC203 2.4 GHz receiver | `3554` | `F5D5` |
| MC203 wired USB mode | `3554` | `F511` |

The application opens only a matching interface and exchanges short vendor
status requests on report ID `0x08`. It waits for a checksum-valid battery
status reply before updating its displayed value. A timeout clears the current
reading rather than showing a stale value.

No ordinary input report is parsed, stored, or logged. The implementation does
not send configuration, firmware, lighting, DPI, button, or macro commands.

## Voltage conversion points

The following voltage points reproduce the MC203 Windows driver's reported
battery conversion behavior through `4110 mV`, which is 100%. Percentages are
interpolated between adjacent points; the curve is intentionally non-linear.

`3050, 3420, 3480, 3540, 3600, 3660, 3720, 3760, 3800, 3840, 3880, 3920, 3940, 3960, 3980, 4000, 4020, 4040, 4060, 4080, 4110 mV`

Above `4110 mV`, MouseBattery deliberately uses a presentation-only voltage
extension: roughly every additional `18 mV` adds one displayed point, up to
`120%`. For example, `4290 mV` displays about `110%`. It is not a claim that
the battery has capacity above 100%; it visualizes voltage headroom above the
vendor’s full-charge threshold.

This data is included as factual compatibility behavior, not as a copy of any
vendor software or configuration file.
