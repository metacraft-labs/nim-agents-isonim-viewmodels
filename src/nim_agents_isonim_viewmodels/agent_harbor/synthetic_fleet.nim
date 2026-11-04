## Invented working sets for the states no capture shows: a fleet larger than
## any capture (forty sessions over five initiatives, which overflows every
## tab strip and list), and one whose names are far longer than real ones.
## Deterministic: the same arguments give the same sessions, so a story or a
## test renders identically on every run.
##
## Everything here is invented -- titles, plans, hosts -- and says so in the
## source label; populated states are built over captured data instead
## (`fixture_source.nim`).

import std/strutils
import nim_agents/agent_harbor/initiatives
import ./records

const
  SyntheticTitles = [
    "Retry telemetry uploads with exponential backoff",
    "Port the route cache to the new storage layer",
    "Split the settings page into tabs",
    "Fix the flaky clock-skew test on CI",
    "Add a dark theme to the onboarding screens",
    "Profile the importer on the large fixture",
    "Document the plugin loading order",
    "Replace the hand-rolled JSON writer",
    "Make the build reproducible on macOS",
    "Trim the release bundle under 40 MB",
    "Add keyboard navigation to the file tree",
    "Migrate the CI matrix to the new runners",
    "Teach the parser the new attribute syntax",
    "Audit the session token lifetimes",
    "Cache the dependency graph between runs",
    "Show test durations in the summary",
    "Stream the build log instead of buffering it",
    "Rename the units module's helpers",
    "Remove the deprecated sync API",
    "Write the upgrade guide for 3.0",
  ]
  SyntheticPlans = [
    ("telemetry-retry", "Telemetry upload retries", "TR"),
    ("route-cache", "Route cache on the new storage layer", "RC"),
    ("settings-redesign", "Settings redesign", "SR"),
    ("ci-runner-migration", "CI runner migration", "CM"),
    ("release-3", "Release 3.0", "R3"),
  ]
  SyntheticOrigins = ["codetracer", "cli", "webui", "tui", "ah-lite", "telegram"]
  SyntheticAgents = [("Claude", "2.1.0"), ("Codex", "0.9.4"), ("Grok", "1.2.0"),
                     ("Opencode", "0.6.1")]
  LongSuffix = " \xE2\x80\x94 and keep the previous behaviour behind a flag until every " &
    "downstream consumer of the old interface has migrated, with a note in the changelog"

proc syntheticSession(i, initiativeCount: int; nowMs: int64;
                      longNames: bool): FleetSession =
  let n = $(i + 1)
  let id = toHex(0xC0FFEE00 + i * 7919, 8).toLowerAscii & "-5e55-4a00-8000-" &
    toHex(i * 104729 + 17, 12).toLowerAscii
  let (software, version) = SyntheticAgents[i mod SyntheticAgents.len]
  # A spread of states, so every mark of a strip and every count shows: one in
  # seven waits on a question, one in five at an ended turn, a few queued,
  # failed and ended, the rest running.
  var status = fsRunning
  var awaiting = false
  var source = ""
  case i mod 10
  of 0: (awaiting, source) = (true, id & ":native-question:" & n)
  of 1, 6: (awaiting, source) = (true, "claude-stop-hook")
  of 3: status = fsQueued
  of 5: status = fsFailed
  of 8: status = fsCompleted
  else: discard
  let started = nowMs - int64(i + 1) * 9 * 60_000
  result = FleetSession(
    id: id,
    prompt: SyntheticTitles[i mod SyntheticTitles.len] &
      (if i >= SyntheticTitles.len: " (" & n & ")" else: "") &
      (if longNames: LongSuffix else: ""),
    agentSoftware: software, agentVersion: version, agentCount: 1,
    host: "host-" & $chr(ord('a') + i mod 6),
    rawStatus: $status, status: status,
    createdAtMs: started, startedAtMs: started,
    updatedAtMs: nowMs - int64(i mod 7) * 60_000,
    endedAtMs: (if status.isActive: 0'i64 else: nowMs - int64(i mod 7) * 60_000),
    awaitingInput: awaiting, awaitingInputSource: source,
    originFrontEnd: SyntheticOrigins[i mod SyntheticOrigins.len],
    branch: (if longNames: "feature/" & SyntheticTitles[i mod SyntheticTitles.len].toLowerAscii.replace(' ', '-') & "-and-the-follow-up-cleanup"
             else: ""),
    labelSource: "invented")
  if initiativeCount > 0 and i mod 8 != 7:
    let plan = SyntheticPlans[i mod initiativeCount]
    result.planId = plan[0]
    result.initiative = plan[1]
  if status == fsFailed:
    result.failureReason = "[exit] status=1"
  result.recent = @[
    FleetActivity(kind: fakToolUse, text: "Ran just test", timestampMs: result.updatedAtMs - 60_000),
    FleetActivity(kind: fakLog, level: "info",
                  text: "assistant: " & (if awaiting: "Which option should I take?" else: "Working on it."),
                  timestampMs: result.updatedAtMs)]

proc syntheticPlan(index: int; longNames: bool): Initiative =
  let (id, title, prefix) = SyntheticPlans[index]
  var progress = MilestoneFileProgress(
    path: "milestones/" & id & ".milestones.org",
    title: title & (if longNames: LongSuffix else: "") & " Milestones",
    status: "in_progress", lastUpdated: "2026-01-15")
  let count = 4 + index * 2
  for m in 0 ..< count:
    let status =
      if m < index + 1: "completed"
      elif m == index + 1: "in_progress"
      elif m == index + 2 and index mod 2 == 1: "blocked"
      elif m == index + 3 and index >= 2: "partially_completed"
      else: "planned"
    progress.milestones.add MilestoneDetail(
      id: prefix & "-M" & $m,
      title: (if longNames: "A milestone whose title runs on well past any width a panel gives it " & $m
              else: ["Specification", "Data model", "Core change", "Front-end",
                     "Migration", "Tests", "Documentation", "Release",
                     "Follow-up", "Clean-up", "Telemetry", "Rollout",
                     "Hardening", "Retrospective"][m mod 14]),
      status: status,
      deliverables: DeliverableCounts(done: (if status == "completed": 3 else: m mod 3), total: 3),
      verifications: VerificationCounts(passing: (if status == "completed": 2 else: 0),
                                        failing: (if status == "blocked": 1 else: 0),
                                        pending: (if status == "completed": 0 else: 2)))
  progress.currentMilestone = prefix & "-M" & $(index + 1)
  progress.summarize()
  Initiative(id: id, title: title & (if longNames: LongSuffix else: ""),
             repository: "orbit-labs/" & id, planPath: progress.path,
             manager: (if index mod 2 == 0: prefix.toLowerAscii & "-manager" else: ""),
             executiveSummary: title & ": " & $progress.summary.completedMilestones &
               " of " & $count & " milestones done; the current one is " &
               progress.summary.currentMilestoneTitle & ".",
             progress: progress)

proc syntheticWorkingSet*(sessions, initiativeCount: int; nowMs: int64;
                          longNames = false): tuple[snapshot: FleetSnapshot,
                                                    initiatives: seq[Initiative]] =
  ## `sessions` invented sessions over `initiativeCount` (at most five)
  ## invented initiatives; one session in eight is launched for none.
  let plans = min(initiativeCount, SyntheticPlans.len)
  result.snapshot = FleetSnapshot(capturedAtMs: nowMs,
                                  sourceLabel: "invented working set")
  for i in 0 ..< sessions:
    result.snapshot.sessions.add syntheticSession(i, plans, nowMs, longNames)
  result.snapshot.total = sessions
  for p in 0 ..< plans:
    var initiative = syntheticPlan(p, longNames)
    for session in result.snapshot.sessions:
      if session.planId == initiative.id: initiative.sessionIds.add session.id
    result.initiatives.add initiative
