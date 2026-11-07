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
## `syntheticTitlesOf`), no two sessions of a set share a title, and no two
## say the same last thing: each one's last activity line follows from its own
## task and its state. An initiative's executive summary is prose that agrees
## with its milestones.

import std/strutils
import nim_agents/agent_harbor/initiatives
import ./records

type
  Work = object
    ## One invented task: its title and what its session last says in each
    ## state it can be in.
    title: string
    tool: string      ## the command or edit it last ran
    running: string   ## what it is doing while it runs
    question: string  ## the question only this task would raise
    failure: string   ## the failure this task hit
    outcome: string   ## what it delivered

func w(title, tool, running, question, failure, outcome: string): Work =
  Work(title: title, tool: tool, running: running, question: question,
       failure: failure, outcome: outcome)

const
  SyntheticPlans = [
    ("telemetry-retry", "Telemetry upload retries", "TR"),
    ("route-cache", "Route cache on the new storage layer", "RC"),
    ("settings-redesign", "Settings redesign", "SR"),
    ("ci-runner-migration", "CI runner migration", "CM"),
    ("release-3", "Release 3.0", "R3"),
  ]
  SyntheticPlanWork: array[5, array[8, Work]] = [
    [w("Retry telemetry uploads with exponential backoff",
       "Ran just test telemetry::retry_backoff",
       "Raising the first retry delay to 2 s and re-running telemetry::retry_backoff.",
       "Should a 429 from the collector count against the retry budget, or wait out its Retry-After?",
       "telemetry::retry_backoff timed out: the fake collector never saw the third attempt.",
       "Uploads now back off 2 s, 4 s, 8 s; telemetry::retry_backoff passes."),
     w("Persist the telemetry queue across restarts",
       "Ran just test telemetry::queue_survives_restart",
       "Writing the queue to telemetry-queue.db before each upload; checking the restart test.",
       "May the queue file live in the cache directory, which a clean-up can delete?",
       "telemetry::queue_survives_restart lost 3 of 10 batches: the queue is flushed after the crash point.",
       "The queue is fsynced before each send and survives a kill -9; 10 of 10 batches arrive."),
     w("Add jitter to the telemetry retry delays",
       "Ran just test telemetry::jitter_spread",
       "Spreading the retry delays with full jitter; measuring the spread over 1,000 clients.",
       "Full jitter or decorrelated jitter? The design doc names neither.",
       "telemetry::jitter_spread found 40% of retries in one 100 ms bucket: the seed is shared.",
       "Retries spread across the whole window; no 100 ms bucket holds more than 3%."),
     w("Cap the telemetry retry budget per hour",
       "Ran just test telemetry::budget_cap",
       "Counting retries per rolling hour and dropping past 120; running telemetry::budget_cap.",
       "When the budget runs out, drop the oldest batches or the newest?",
       "telemetry::budget_cap allowed 121 retries: the window resets on the hour, not rolling.",
       "The budget is a rolling hour of 120 retries; past it the oldest batch is dropped."),
     w("Report dropped telemetry batches on the status page",
       "Ran just test status_page::dropped_batches",
       "Adding a Dropped batches row to the status page; snapshotting the page in both themes.",
       "Should the status page show dropped batches per hour or since start-up?",
       "status_page::dropped_batches snapshot differs: the new row pushes the footer off the page.",
       "The status page lists dropped batches for the last 24 hours; both snapshots updated."),
     w("Test telemetry retries against a flaky collector",
       "Ran just test telemetry::flaky_collector",
       "Driving uploads through a collector that drops every third request.",
       "Is a 30 s run long enough for the flaky-collector test on CI, or should it be nightly?",
       "telemetry::flaky_collector hung: the collector stub never closes the keep-alive connection.",
       "The flaky-collector test runs in 12 s and delivers every batch exactly once."),
     w("Document the telemetry retry settings",
       "Edited docs/telemetry.md",
       "Writing the retry settings table in docs/telemetry.md from the config schema.",
       "Should the docs show the defaults for the self-hosted build too, or only the cloud ones?",
       "The docs build fails: telemetry.md links to a settings anchor that no longer exists.",
       "docs/telemetry.md documents the five retry settings with their defaults and limits."),
     w("Expose telemetry retry counters as metrics",
       "Ran just test metrics::retry_counters",
       "Registering telemetry_retries_total and telemetry_dropped_total with the metrics exporter.",
       "Label the retry counter by collector host, or would that blow up the cardinality?",
       "metrics::retry_counters failed: the exporter registers telemetry_retries_total twice.",
       "telemetry_retries_total and telemetry_dropped_total are exported and documented.")],
    [w("Port the route cache to the new storage layer",
       "Ran cargo test -p route-cache",
       "Moving RouteCache::get and ::put onto the storage layer's batch API.",
       "Keep the old cache behind a feature flag for one release, or remove it now?",
       "cargo test -p route-cache: 4 failures, the batch API returns keys in another order.",
       "RouteCache reads and writes through the storage layer; all 52 route-cache tests pass."),
     w("Migrate cached routes without a cold start",
       "Ran just bench route-cache-migration",
       "Copying the cached routes into the new layer in the background while serving from the old one.",
       "Is a 90 s window with both caches warm acceptable on the smallest instance size?",
       "The migration ran out of memory at 1.2 M routes: both caches hold every entry at once.",
       "Routes migrate in 50k batches with no cold start; the p99 stays under 8 ms."),
     w("Benchmark route cache reads on the new layer",
       "Ran just bench route-cache-reads",
       "Benchmarking 10 M route lookups on the new layer against the old cache.",
       "Benchmark on the production key distribution, or on the uniform synthetic one?",
       "The read benchmark crashed at 6 M lookups: the bench harness leaks file handles.",
       "Reads on the new layer are 18% faster at p50 and 6% at p99."),
     w("Expire stale routes when the storage layer compacts",
       "Ran cargo test -p route-cache compaction",
       "Hooking route expiry into the storage layer's compaction callback.",
       "Should a route that expires during compaction be served once more, or dropped at once?",
       "The route-cache compaction test failed: an expired route was served after compaction.",
       "Compaction drops expired routes; no stale route is served after it."),
     w("Remove the old route cache backend",
       "Ran rg OldRouteCache",
       "Deleting the old backend and its 14 call sites.",
       "Two plugins still import OldRouteCache; remove them too, or leave a shim?",
       "The build broke: the admin tool still constructs OldRouteCache.",
       "The old backend is gone: 2,300 lines deleted, no remaining callers."),
     w("Add route cache hit rates to the dashboard",
       "Ran just test dashboard::route_cache_panel",
       "Adding a hit-rate panel to the service dashboard, fed by the new cache counters.",
       "Show the hit rate per region or one global number on the dashboard?",
       "dashboard::route_cache_panel failed: the counter is named route_cache_hits, not _hit_total.",
       "The dashboard shows the route cache hit rate per region, 94% in the last hour."),
     w("Fix the route cache eviction race",
       "Ran cargo test -p route-cache eviction -- --test-threads 32",
       "Reproducing the eviction race with 32 threads under loom.",
       "Take the shard lock for eviction, or make the entry state an atomic? The trade-off is latency.",
       "loom found the race again: eviction and refresh both win for the same entry.",
       "Eviction takes the shard lock; loom explores 40k interleavings with no race."),
     w("Write the route cache migration guide",
       "Edited docs/route-cache-migration.md",
       "Writing the operator steps for the route cache migration, with the rollback.",
       "Does the guide need a rollback section for operators who already migrated?",
       "The guide's example config fails validation: storage.batch_size is a string there.",
       "The migration guide covers the steps, the metrics to watch and the rollback.")],
    [w("Split the settings page into tabs",
       "Ran just test settings::tabs",
       "Splitting SettingsPage into General, Account, Notifications and Advanced tabs.",
       "Should Advanced be a tab of its own, or a section at the bottom of General?",
       "settings::tabs failed: the Notifications tab renders the General form.",
       "Settings is four tabs; every setting is reachable and the snapshot tests pass."),
     w("Add search to the settings page",
       "Ran just test settings::search",
       "Indexing every setting's label and help text for the settings search field.",
       "Should a search hit in another tab switch to it, or list the hits across tabs?",
       "settings::search found nothing for proxy: the Advanced tab is never indexed.",
       "Search finds a setting in any tab and jumps to it; 24 search tests pass."),
     w("Move the account settings into their own tab",
       "Ran just test settings::account_tab",
       "Moving the email, password and two-factor settings into the Account tab.",
       "Keep a link to the Account tab where the account settings used to be?",
       "settings::account_tab failed: two-factor enrolment still opens the old page.",
       "Account settings live in their own tab, including two-factor enrolment."),
     w("Keep unsaved settings when switching tabs",
       "Ran just test settings::unsaved_changes",
       "Keeping each tab's draft in the settings store instead of the tab component.",
       "Warn about unsaved changes when the user closes the window, or save them silently?",
       "settings::unsaved_changes failed: the draft is lost when the Account tab remounts.",
       "Drafts survive tab switches; closing the window asks before discarding them."),
     w("Add keyboard navigation to the settings tabs",
       "Ran just test settings::keyboard_navigation",
       "Wiring arrow keys and Home/End between the settings tabs.",
       "Should Ctrl+Tab cycle the settings tabs, given it already cycles windows?",
       "settings::keyboard_navigation failed: focus leaves the tab list on the last tab.",
       "The settings tabs follow the ARIA tabs pattern; focus never leaves the list."),
     w("Show which settings need a restart",
       "Ran just test settings::restart_badges",
       "Marking the six restart-only settings and showing a Restart now banner after a change.",
       "Offer to restart from the banner, or only say that a restart is needed?",
       "settings::restart_badges failed: the banner appears for settings that apply at once.",
       "The six restart-only settings carry a badge, and the banner offers a restart."),
     w("Reset a settings tab to its defaults",
       "Ran just test settings::reset_tab",
       "Adding Reset to defaults to each tab, with a confirmation.",
       "Should resetting a tab also reset the settings that need a restart?",
       "settings::reset_tab failed: reset also clears the account email.",
       "Each tab resets to its defaults after a confirmation; account fields are kept."),
     w("Write screenshot tests for the settings tabs",
       "Ran just test-screenshots settings",
       "Recording screenshot baselines for the four settings tabs in both themes.",
       "Record the baselines at 1x only, or at 2x for the high-density screens too?",
       "The screenshot run failed: the light-theme baseline of Advanced is 2 px taller on CI.",
       "Eight screenshot baselines recorded; they pass on CI and locally.")],
    [w("Migrate the CI matrix to the new runners",
       "Ran gh workflow run ci.yml --ref ci/new-runners",
       "Moving the Linux jobs of the matrix to the new runner labels.",
       "Keep the old runners as a fallback label for a week, or cut over at once?",
       "The matrix run failed on the new runners: the image lacks protoc.",
       "Every Linux job of the matrix runs on the new runners; the matrix is green."),
     w("Cache the dependency graph between CI runs",
       "Ran gh workflow run ci.yml --ref ci/cache-deps",
       "Caching the resolved dependency graph keyed by the lockfile hash.",
       "Is a cache miss on every lockfile change acceptable, or should the key be per package?",
       "The cached graph was stale: the key ignores the toolchain version.",
       "The dependency graph is cached by lockfile and toolchain; setup takes 40 s, not 6 min."),
     w("Fix the flaky clock-skew test on the new runners",
       "Ran just test time::clock_skew --repeat 200",
       "Repeating time::clock_skew 200 times on a new runner to catch the flake.",
       "Is the 50 ms skew tolerance part of the spec, or may the test widen it?",
       "time::clock_skew failed 3 of 200 runs: the runner's NTP step lands mid-test.",
       "time::clock_skew uses a fake clock and passed 1,000 of 1,000 runs."),
     w("Move the macOS jobs to the new runner pool",
       "Ran gh workflow run ci.yml --ref ci/macos-pool",
       "Moving the macOS jobs to the new pool and pinning Xcode 16.2.",
       "Run the macOS jobs on every push, or only on the merge queue?",
       "The macOS jobs failed: the new pool's runners have no signing keychain.",
       "The macOS jobs run on the new pool with Xcode 16.2; codesigning works."),
     w("Stream the CI build log instead of buffering it",
       "Ran gh workflow run ci.yml --ref ci/stream-log",
       "Piping the build output to the log as it arrives instead of at the end.",
       "Should the streamed log keep the ANSI colours, or strip them?",
       "The streamed log interleaves two jobs' lines: they share one pipe.",
       "The build log streams line by line; a stuck job shows where it stopped."),
     w("Show test durations in the CI summary",
       "Ran just test ci_summary::durations",
       "Adding the slowest ten tests and their durations to the CI summary.",
       "Ten slowest tests, or every test over 5 s?",
       "ci_summary::durations failed: durations from retried tests are counted twice.",
       "The CI summary lists the ten slowest tests; a retried test counts once."),
     w("Retire the old runner images",
       "Ran gh api repos/:owner/:repo/actions/runners",
       "Listing the jobs that still request the old runner images.",
       "Two release branches still use the old images; retire them anyway?",
       "Retiring the images broke the 2.x release branch: it still requests ubuntu-20.04.",
       "The old images are retired; the 2.x branch moved to the new ones."),
     w("Make the CI build reproducible on macOS",
       "Ran just build --check-reproducible",
       "Building twice on macOS and diffing the outputs.",
       "Is a differing code signature acceptable if the unsigned binaries match?",
       "The macOS builds differ: the archive records the build directory's path.",
       "Two macOS builds are byte-identical before signing.")],
    [w("Write the upgrade guide for 3.0",
       "Edited docs/upgrading-to-3.0.md",
       "Writing the breaking changes section of the 3.0 upgrade guide.",
       "Should the guide cover upgrading from 1.x directly, or only from 2.x?",
       "The docs check failed: the guide links to the removed sync API reference.",
       "The 3.0 upgrade guide covers every breaking change with a before and after."),
     w("Remove the deprecated sync API for 3.0",
       "Ran rg 'sync_' --type rust",
       "Removing sync_fetch, sync_store and their 31 tests.",
       "The CLI still calls sync_fetch in one place; port it or drop that command?",
       "The build broke: the CLI's export command still calls sync_fetch.",
       "The sync API is removed; the CLI's export uses the async API."),
     w("Trim the 3.0 release bundle under 40 MB",
       "Ran just bundle --report-sizes",
       "Splitting the locale data out of the main bundle; it is 9 MB of the 46.",
       "May the locale data load on first use, which needs network on first start?",
       "The trimmed bundle fails to start offline: the default locale was split out too.",
       "The 3.0 bundle is 37.8 MB; locales other than English load on first use."),
     w("Rename the units module's helpers for 3.0",
       "Ran just test units",
       "Renaming to_metres and to_feet to metres_from and feet_from across the code base.",
       "Keep deprecated aliases for the old helper names through 3.x?",
       "just test units failed: a doc test still calls to_metres.",
       "The units helpers are renamed, with deprecated aliases until 4.0."),
     w("Draft the 3.0 release notes",
       "Ran git log v2.9.0..release/3.0 --oneline",
       "Grouping the 214 commits since 2.9 into the release notes' sections.",
       "Should the release notes credit outside contributors by name?",
       "The release notes generator stopped: two commits have no conventional type.",
       "The 3.0 release notes draft is ready for review, grouped into six sections."),
     w("Bump the minimum supported runtime for 3.0",
       "Ran just test --runtime 1.82",
       "Raising the minimum runtime to 1.82 and removing the compatibility shims.",
       "Announce the new minimum runtime in the 2.9 release too?",
       "The tests failed on 1.82: the async-closure shim is still needed by the CLI.",
       "3.0 requires runtime 1.82; four compatibility shims removed."),
     w("Tag the 3.0 release candidate",
       "Ran just release-candidate 3.0.0-rc.1",
       "Building the 3.0.0-rc.1 artefacts on all three platforms.",
       "Publish the release candidate to the beta track, or only to nightly?",
       "The rc.1 build failed on Windows: the installer exceeds the old size limit.",
       "3.0.0-rc.1 is tagged and its artefacts are published on the beta track."),
     w("Audit the 3.0 changelog against merged work",
       "Ran gh pr list --search milestone:3.0 --state merged",
       "Matching the 87 merged pull requests of the 3.0 milestone against the changelog.",
       "Three merged pull requests have no changelog entry; add them, or are they internal?",
       "The audit stopped: the API returned only the first 30 merged pull requests.",
       "Every merged 3.0 pull request is in the changelog or marked internal.")],
  ]
    ## Each initiative's sessions, in launch order: the title (a session under
    ## an initiative works on that initiative) and what the session last says
    ## in each state it can be in, which follows from its own task (`Work`).
  SyntheticLooseWork = [
    w("Profile the importer on the large fixture",
      "Ran just profile importer fixtures/large.csv",
      "Profiling the importer on the 2 GB fixture; parsing takes 70% of the time.",
      "Profile with the release allocator, or the debug one the bug report used?",
      "The profiler crashed at 1.4 GB: the importer is built without frame pointers.",
      "The importer spends 70% in CSV parsing; a faster parser would halve the run."),
    w("Replace the hand-rolled JSON writer",
      "Ran just test json",
      "Replacing the hand-rolled JSON writer with the serde serializer.",
      "The old writer sorts keys; must the new output keep that order?",
      "just test json failed: the new writer escapes forward slashes differently.",
      "The JSON writer is serde's; byte-identical output for the 40 golden files."),
    w("Teach the parser the new attribute syntax",
      "Ran just test parser::attributes",
      "Adding the #[name = value] attribute form to the grammar.",
      "Allow attributes on match arms, which the proposal leaves open?",
      "parser::attributes failed: the new rule conflicts with the index expression.",
      "The parser accepts the new attribute syntax; 17 new grammar tests pass."),
    w("Audit the session token lifetimes",
      "Ran rg 'token_ttl|expires_in'",
      "Listing every place a session token's lifetime is set.",
      "Refresh tokens live 90 days; is that the intended policy or a leftover?",
      "The audit script failed: two services read the lifetime from an unset variable.",
      "Every token lifetime is listed; two services default to no expiry."),
    w("Add a dark theme to the onboarding screens",
      "Ran just test-screenshots onboarding",
      "Moving the onboarding screens' colours onto the theme tokens.",
      "The illustrations are drawn for light backgrounds; invert them or commission dark ones?",
      "The dark onboarding screenshots fail contrast: the step counter is grey on grey.",
      "The onboarding screens follow the theme; contrast passes in both."),
    w("Document the plugin loading order",
      "Edited docs/plugins.md",
      "Documenting the order plugins load in and how dependencies change it.",
      "Is the alphabetical tie-break part of the contract, or an accident?",
      "The doc example fails: plugin b loads before a, contrary to the text.",
      "docs/plugins.md explains the loading order, its tie-break and cycles."),
    w("Fix the typo in the CLI help text",
      "Ran rg 'recieve' src/cli",
      "Fixing recieve in the help of the sync and fetch commands.",
      "Fix the same typo in the man page, which is generated from another source?",
      "The help-text snapshot test failed: it pinned the misspelling.",
      "The typo is fixed in the help, the man page and the snapshot."),
    w("Investigate the slow start on cold caches",
      "Ran just trace-startup --cold",
      "Tracing a cold start; 3.1 s pass before the first frame.",
      "Measure on a machine with an HDD too, where the bug report came from?",
      "The startup trace is empty: tracing starts after the slow phase.",
      "A cold start spends 2.4 s reading the font cache; caching it brings it to 0.7 s."),
    w("Update the copyright headers",
      "Ran just headers --check",
      "Updating the year in 412 source headers.",
      "Change the headers of the vendored files too, or only our own?",
      "just headers --check failed: 6 generated files have no header to update.",
      "412 headers updated; the generated files take their header from the template."),
    w("Answer the question about the config format",
      "Read docs/config.md",
      "Reading how nested tables are merged to answer the question.",
      "Did they mean the config file or the environment overrides?",
      "The example in the answer fails to parse: inline tables cannot span lines.",
      "Answered: nested tables merge key by key, and arrays are replaced."),
  ]
    ## One-off work, launched for no initiative.
  SyntheticSummaries = [
    "Telemetry uploads that fail are retried with exponential backoff and " &
      "jitter instead of being dropped on the first collector error, and the " &
      "queue survives a restart. The specification is agreed; the persisted " &
      "queue's data model is being written, and the retry budget waits on it.",
    "The route cache moves onto the new storage layer without a cold start, " &
      "and the old backend is removed. The data model and the specification " &
      "are done and the core port is under way; the dashboard work is blocked " &
      "until the cache exports its hit counters.",
    "The settings page is split into four tabs with search, unsaved drafts " &
      "and restart badges. The tab structure and the account move are done; " &
      "the front-end tabs are in progress and their screenshot tests are half " &
      "recorded.",
    "CI moves its Linux and macOS jobs to the new runner pool, with a cached " &
      "dependency graph and a streamed build log. The matrix runs on the new " &
      "runners; the migration of the macOS jobs is in progress, and the test " &
      "milestone is blocked on the clock-skew flake.",
    "The 3.0 release removes the deprecated sync API, trims the bundle under 40 MB " &
      "and ships an upgrade guide. The breaking changes are merged and " &
      "documented; the release candidate's tests are running, and the release " &
      "notes are being drafted.",
  ]
    ## Each invented initiative's executive summary: what it delivers and
    ## where it stands, in prose, as an initiative's plan states it. It
    ## agrees with the milestones `syntheticPlan` gives it (how many are
    ## done, the current one, a blocked one).
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

proc pick(pool: openArray[Work]; k: int): Work =
  ## The `k`th task of `pool`; past its end a numbered follow-up of an earlier
  ## one, so a set never repeats a title or a last line (no story set
  ## reaches this).
  if k < pool.len: return pool[k]
  let n = $(k div pool.len)
  let base = pool[k mod pool.len]
  proc again(line: string): string = line & " (follow-up " & n & ")"
  Work(title: base.title & ", follow-up " & n, tool: again(base.tool),
       running: again(base.running), question: again(base.question),
       failure: again(base.failure), outcome: again(base.outcome))

proc titlesOf(pool: openArray[Work]): seq[string] =
  for work in pool: result.add work.title

proc syntheticTitlesOf*(planId: string): seq[string] =
  ## The titles an invented initiative's sessions take, in launch order
  ## (`""`: the titles of sessions launched for no initiative). A set's
  ## session titled outside its initiative's titles is incoherent.
  if planId.len == 0: return titlesOf(SyntheticLooseWork)
  for i, plan in SyntheticPlans:
    if plan[0] == planId: return titlesOf(SyntheticPlanWork[i])

proc launchedFor(i, initiativeCount: int): int =
  ## The initiative session `i` is launched for, or -1 for none: one session
  ## in seven is launched for none.
  if initiativeCount <= 0 or i mod 7 == 6: -1 else: i mod initiativeCount

proc lowerFirst(text: string): string =
  if text.len == 0: text else: text[0].toLowerAscii & text[1 .. ^1]

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
  let work =
    if plan < 0: pick(SyntheticLooseWork, titleIndex)
    else: pick(SyntheticPlanWork[plan], titleIndex)
  let title = work.title
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
  # What it last did follows from its own task and its state: a question only
  # this task would raise, the test it is running, the failure it hit, what
  # it delivered. No two sessions of a set say the same last thing.
  let (said, level) =
    if awaiting and source == "claude-stop-hook":
      ("assistant: " & work.outcome & " Ready for the next step.", "info")
    elif awaiting: ("assistant: " & work.question, "info")
    else:
      case status
      of fsQueued: ("assistant: Queued; waiting for an agent slot to " &
                    lowerFirst(title) & ".", "info")
      of fsFailed: ("assistant: " & work.failure, "error")
      of fsCompleted: ("assistant: " & work.outcome, "info")
      else: ("assistant: " & work.running, "info")
  # A queued session has run nothing yet.
  if status != fsQueued:
    result.recent.add FleetActivity(kind: fakToolUse, text: work.tool,
                                    timestampMs: result.updatedAtMs - 60_000)
  result.recent.add FleetActivity(kind: fakLog, level: level, text: said,
                                  timestampMs: result.updatedAtMs)

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
             executiveSummary: SyntheticSummaries[index],
             progress: progress)

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
