# Cloudflare Tunnel DNS Route Helper

Manages proxied CNAME records used for Cloudflare tunnel routing, and tracks the set of routes it starts so they can be listed and disabled later.

## Language

**Route**:
A `(zone, record)` pair plus its tunnel target (CNAME) that points a hostname through a Cloudflare tunnel.
_Avoid_: Track, record, entry

**Tracked route**:
A route that this tool has successfully started (`enable`) and recorded in the local registry, so it can be listed and disabled later.
_Avoid_: Zone, tracked zone

**Registry**:
The local tab-delimited sidecar file (`.tracked_routes`) listing every tracked route. Its directory comes from `CF_TRACKED_ROUTES`, defaulting to `${XDG_STATE_HOME:-$HOME}/cf-dns-cname-route`.
_Avoid_: List, config, database

**Current route**:
The route described by the currently loaded environment (`CF_ZONE_ID` + `CF_RECORD_NAME` + `CF_TUNNEL_CNAME`). The plain `enable`/`disable`/`status` commands act on the current route only.
_Avoid_: Active route

**Other-zone route**:
A tracked route whose zone differs from the currently loaded `CF_ZONE_ID`, so it can be listed but not live-queried or disabled without first loading its environment.
_Avoid_: Foreign route, external route
