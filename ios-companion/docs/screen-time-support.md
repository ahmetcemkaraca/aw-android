# Screen Time support matrix — development candidate

No iOS device, region, or Apple entitlement has been tested or approved. This table
records the current implementation boundary, not a supported-device promise.

| Surface | iPhone | iPad | Region / entitlement | Candidate behavior |
| --- | --- | --- | --- | --- |
| Manual entries and local report | Source only; Xcode/device run pending | Source only; Xcode/device run pending | No special entitlement | AES-GCM encrypted local store; no network |
| Family Controls authorization | Unverified | Unverified | Distribution entitlement unrequested/unapproved | Requested only after explicit user action; declines leave manual mode |
| Family Activity Picker | Unverified | Unverified | Regional/API behavior unverified | System picker returns opaque tokens; app does not enumerate names |
| Automatic Screen Time reports | Unavailable | Unavailable | No DeviceActivity report extension or approved entitlement | UI says unavailable; no hidden collection |
| Desktop window/title or browser tracking | Unsupported | Unsupported | Not applicable | No API, watcher, or claim |
| E2EE sync | Unavailable | Unavailable | Signed iOS bridge/relay consent absent | No request is sent |

Before changing a cell to supported, run the iOS simulator and physical-device
flows, confirm entitlement assignment and regional behavior, and attach the results
to the EPIC-10 final acceptance record.
