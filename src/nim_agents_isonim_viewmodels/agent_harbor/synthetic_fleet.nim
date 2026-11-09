## Invented working sets for the states no capture shows: a fleet larger than
## any capture (forty sessions over five initiatives, which overflows every
## tab strip and list), one whose names are far longer than real ones, and the
## small working set a front-end's default stories show.
## Deterministic: the same arguments give the same sessions, so a story or a
## test renders identically on every run.
##
## Everything here is invented -- titles, plans, hosts -- and says so in the
## source label. A set is coherent: a session launched for an initiative works
## on that initiative (its title comes from the initiative's own titles,
## `syntheticTitlesOf`), and no two sessions of a set share a title.

import std/strutils
import nim_agents/agent_harbor/initiatives
import ./records

const
  SyntheticPlans = [
    ("telemetry-retry", "Telemetry upload retries", "TR"),
    ("route-cache", "Route cache on the new storage layer", "RC"),
    ("settings-redesign", "Settings redesign", "SR"),
    ("ci-runner-migration", "CI runner migration", "CM"),
    ("release-3", "Release 3.0", "R3"),
  ]
  SyntheticPlanTitles: array[5, array[8, string]] = [
    ["Retry telemetry uploads with exponential backoff",
     "Persist the telemetry queue across restarts",
     "Add jitter to the telemetry retry delays",
     "Cap the telemetry retry budget per hour",
     "Report dropped telemetry batches on the status page",
     "Test telemetry retries against a flaky collector",
     "Document the telemetry retry settings",
     "Expose telemetry retry counters as metrics"],
    ["Port the route cache to the new storage layer",
     "Migrate cached routes without a cold start",
     "Benchmark route cache reads on the new layer",
     "Expire stale routes when the storage layer compacts",
     "Remove the old route cache backend",
     "Add route cache hit rates to the dashboard",
     "Fix the route cache eviction race",
     "Write the route cache migration guide"],
    ["Split the settings page into tabs",
     "Add search to the settings page",
     "Move the account settings into their own tab",
     "Keep unsaved settings when switching tabs",
     "Add keyboard navigation to the settings tabs",
     "Show which settings need a restart",
     "Reset a settings tab to its defaults",
     "Write screenshot tests for the settings tabs"],
    ["Migrate the CI matrix to the new runners",
     "Cache the dependency graph between CI runs",
     "Fix the flaky clock-skew test on the new runners",
     "Move the macOS jobs to the new runner pool",
     "Stream the CI build log instead of buffering it",
     "Show test durations in the CI summary",
     "Retire the old runner images",
     "Make the CI build reproducible on macOS"],
    ["Write the upgrade guide for 3.0",
     "Remove the deprecated sync API for 3.0",
     "Trim the 3.0 release bundle under 40 MB",
     "Rename the units module's helpers for 3.0",
     "Draft the 3.0 release notes",
     "Bump the minimum supported runtime for 3.0",
     "Tag the 3.0 release candidate",
     "Audit the 3.0 changelog against merged work"],
  ]
    ## Each initiative's sessions' titles, in launch order: a session under an
    ## initiative works on that initiative.
  SyntheticLooseTitles = [
    "Profile the importer on the large fixture",
    "Replace the hand-rolled JSON writer",
    "Teach the parser the new attribute syntax",
    "Audit the session token lifetimes",
    "Add a dark theme to the onboarding screens",
    "Document the plugin loading order",
    "Fix the typo in the CLI help text",
    "Investigate the slow start on cold caches",
    "Update the copyright headers",
    "Answer the question about the config format",
  ]
    ## One-off work, launched for no initiative.
  SyntheticOrigins = ["codetracer", "cli", "webui", "codetracer", "tui", "telegram"]
    ## A third of the sessions start in this front-end; the rest elsewhere.
  SyntheticAgents = [("Claude", "2.1.0"), ("Codex", "0.9.4"), ("Grok", "1.2.0"),
                     ("Opencode", "0.6.1")]
  LongSuffix = " \xE2\x80\x94 and keep the previous behaviour behind a flag until every " &
    "downstream consumer of the old interface has migrated, with a note in the changelog"
  DefaultSessions* = 14
  DefaultInitiatives* = 4
    ## The default working set's size: enough sessions that a strip
    ## overflows at laptop width and every state shows, over four initiatives.

proc pick(pool: openArray[string]; k: int): string =
  ## The `k`th title of `pool`; past its end a numbered follow-up, so a set
  ## never repeats a title (no story set reaches this).
  if k < pool.len: pool[k]
  else: pool[k mod pool.len] & ", follow-up " & $(k div pool.len)

proc syntheticTitlesOf*(planId: string): seq[string] =
  ## The titles an invented initiative's sessions take, in launch order
  ## (`""`: the titles of sessions launched for no initiative). A set's
  ## session titled outside its initiative's titles is incoherent.
  if planId.len == 0: return @SyntheticLooseTitles
  for i, plan in SyntheticPlans:
    if plan[0] == planId: return @(SyntheticPlanTitles[i])

proc launchedFor(i, initiativeCount: int): int =
  ## The initiative session `i` is launched for, or -1 for none: one session
  ## in seven is launched for none.
  if initiativeCount <= 0 or i mod 7 == 6: -1 else: i mod initiativeCount

proc syntheticSession(i, initiativeCount, titleIndex: int; nowMs: int64;
                      longNames: bool): FleetSession =
  let n = $(i + 1)
  let id = toHex(0xC0FFEE00 + i * 7919, 8).toLowerAscii & "-5e55-4a00-8000-" &
    toHex(i * 104729 + 17, 12).toLowerAscii
  let (software, version) = SyntheticAgents[i mod SyntheticAgents.len]
  # A spread of states, so every mark of a strip and every count shows: one in
  # seven waits on a question, one in five at an ended turn, a few queued,
  # failed and ended, the rest running. The state is drawn from a mix of the
  # index and its initiative round, so an initiative's sessions are not all
  # in one state.
  var status = fsRunning
  var awaiting = false
  var source = ""
  case (i * 7 + i div max(1, initiativeCount)) mod 10
  of 0: (awaiting, source) = (true, id & ":native-question:" & n)
  of 1, 6: (awaiting, source) = (true, "claude-stop-hook")
  of 3: status = fsQueued
  of 5: status = fsFailed
  of 8: status = fsCompleted
  else: discard
  let plan = launchedFor(i, initiativeCount)
  let title =
    if plan < 0: pick(SyntheticLooseTitles, titleIndex)
    else: pick(SyntheticPlanTitles[plan], titleIndex)
  let started = nowMs - int64(i + 1) * 9 * 60_000
  result = FleetSession(
    id: id,
    prompt: title & (if longNames: LongSuffix else: ""),
    agentSoftware: software, agentVersion: version, agentCount: 1,
    host: "host-" & $chr(ord('a') + i mod 6),
    rawStatus: $status, status: status,
    createdAtMs: started, startedAtMs: started,
    updatedAtMs: nowMs - int64(i mod 7) * 60_000,
    endedAtMs: (if status.isActive: 0'i64 else: nowMs - int64(i mod 7) * 60_000),
    awaitingInput: awaiting, awaitingInputSource: source,
    originFrontEnd: SyntheticOrigins[i mod SyntheticOrigins.len],
    branch: (if longNames: "feature/" & title.toLowerAscii.replace(' ', '-') & "-and-the-follow-up-cleanup"
             else: ""),
    labelSource: "invented")
  if plan >= 0:
    result.planId = SyntheticPlans[plan][0]
    result.initiative = SyntheticPlans[plan][1]
  if status == fsFailed:
    result.failureReason = "[exit] status=1"
  # What it last did, in keeping with its state: a question waits on an
  # answer, an ended turn on the next instruction, and so on.
  let said =
    if awaiting and source == "claude-stop-hook": "assistant: Done for now; ready for the next instruction."
    elif awaiting: "assistant: Should the old behaviour stay behind a flag, or go?"
    else:
      case status
      of fsQueued: "assistant: Queued until an agent slot frees up."
      of fsFailed: "assistant: The build failed; stopping here."
      of fsCompleted: "assistant: Finished; the tests pass."
      else: "assistant: Running the tests again after the change."
  result.recent = @[
    FleetActivity(kind: fakToolUse,
                  text: (if status == fsQueued: "Waited for a free agent slot" else: "Ran just test"),
                  timestampMs: result.updatedAtMs - 60_000),
    FleetActivity(kind: fakLog, level: "info", text: said,
                  timestampMs: result.updatedAtMs)]

proc syntheticSummary(title: string; progress: MilestoneFileProgress): string =
  ## An invented plan's executive summary: how many milestones are done and
  ## which one is current.
  title & ": " & $progress.summary.completedMilestones & " of " &
    $progress.milestones.len & " milestones done; the current one is " &
    progress.summary.currentMilestoneTitle & "."

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
             executiveSummary: syntheticSummary(title, progress),
             progress: progress)

proc readyForCompletion*(initiative: var Initiative; milestoneId: string): bool =
  ## The invented plan made coherent with a progress event that is about to
  ## complete `milestoneId`, as a plan's author leaves it before the event:
  ## the milestone's deliverables all done and its tests all passing, and the
  ## executive summary already stating the plan as it reads once the
  ## milestone is completed (the next milestone current). The status itself
  ## is left to the event (`applyMilestoneStatus`), so the event still
  ## changes the plan. False, and nothing changed, for a milestone the plan
  ## does not hold.
  var found = false
  for m in initiative.progress.milestones.mitems:
    if m.id == milestoneId:
      found = true
      m.deliverables.done = m.deliverables.total
      m.verifications.passing += m.verifications.pending + m.verifications.failing
      m.verifications.pending = 0
      m.verifications.failing = 0
  if not found: return false
  var after = initiative.progress
  discard after.applyMilestoneStatus(milestoneId, "completed")
  initiative.progress.summarize()
  let title = initiative.title.replace(LongSuffix, "")
  initiative.executiveSummary = syntheticSummary(title, after)
  true

proc syntheticWorkingSet*(sessions, initiativeCount: int; nowMs: int64;
                          longNames = false): tuple[snapshot: FleetSnapshot,
                                                    initiatives: seq[Initiative]] =
  ## `sessions` invented sessions over `initiativeCount` (at most five)
  ## invented initiatives; one session in seven is launched for none. Each
  ## session's title is the next of its initiative's titles.
  let plans = min(initiativeCount, SyntheticPlans.len)
  result.snapshot = FleetSnapshot(capturedAtMs: nowMs,
                                  sourceLabel: "invented working set")
  var used = newSeq[int](plans + 1)   # titles taken, per initiative; last: none
  for i in 0 ..< sessions:
    let plan = launchedFor(i, plans)
    let slot = if plan < 0: plans else: plan
    result.snapshot.sessions.add syntheticSession(i, plans, used[slot], nowMs, longNames)
    inc used[slot]
  result.snapshot.total = sessions
  for p in 0 ..< plans:
    var initiative = syntheticPlan(p, longNames)
    for session in result.snapshot.sessions:
      if session.planId == initiative.id: initiative.sessionIds.add session.id
    result.initiatives.add initiative

proc defaultWorkingSet*(nowMs: int64): tuple[snapshot: FleetSnapshot,
                                              initiatives: seq[Initiative]] =
  ## The working set a front-end's default stories show:
  ## `DefaultSessions` sessions over `DefaultInitiatives` initiatives.
  syntheticWorkingSet(DefaultSessions, DefaultInitiatives, nowMs)
