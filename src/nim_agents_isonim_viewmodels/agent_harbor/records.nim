## The Agent Harbor fleet records, re-exported from `nim_agents`.
##
## The records (`FleetSession`, `FleetSnapshot`, `LifecycleFrame`, …) and
## their wire decoding are app-agnostic and signal-free, so they live in
## nim-agents (`nim_agents/agent_harbor/fleet_records`); this module keeps the
## import path the viewmodels and their consumers have used since the records
## began here.

import nim_agents/agent_harbor/fleet_records

export fleet_records
