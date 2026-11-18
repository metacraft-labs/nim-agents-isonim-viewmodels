## Invented changes for the Changes panel's stories and tests: a plan with
## every review-record subsection, and the change it describes as a committed
## and an uncommitted diff of the same invented repository
## (`orbit-labs/telemetry-relay`). Every name, path, id, line and person in
## this module is invented.
##
## The plan (`RelayPlan`) holds structured Spec Changes entries in every
## approval state (approved by a feedback request and by a relay, pending
## with and without an open approval request, editorial), Verification
## entries in every status (one annotated), prose Implementation Details and
## Key Source Files. The committed diff (`RelayCommitted`) adds a
## requirement heading and changes another in a spec file (two tier-1
## cards), changes `AGENTS.md` (a tier-2 card) and another spec, and holds a
## modified, a renamed, a deleted, a binary and a deeply nested file; the
## uncommitted diff (`RelayUncommitted`) changes one of those files again and
## adds a test. Two of the plan's key source files are in the change, so they
## come first in the Code tab.
##
## `changesFixture` builds the source of each story (`ChangesFixtureNames`);
## every source that holds a change is a `ScriptedActionSource`, so a
## story's writes are answered from its script and recorded (`loading` and
## `error` are the seam's pending and failing sources).

import ./data_source
import ./scripted_actions

export data_source, scripted_actions

const
  RelayTaskId* = "relay-backpressure"
  RelaySessionId* = "5ca1ab1e-0c01-4c00-8000-00000000c001"
  RelayPlanPath* = "milestones/Relay-Backpressure.milestones.org"
  RelayApprovalRequest* = "fb-relay-7"
    ## The feedback request open for approving `specs/Relay-Metrics.md`.
  SinceMain* = DiffBase(id: MergeBase, label: "Since main")
  SessionChanges* = DiffBase(id: "session", label: "Session changes")

  RelayPlan* = """
#+TITLE: Relay Backpressure Milestones

* Milestones

** RB-M1: Specify the backpressure contract
   :PROPERTIES:
   :status: completed
   :END:

*** Spec Changes
    - spec: specs/Relay-Backpressure.md
      sections: RELAY-AREQ2 Bounded queues; RELAY-AREQ4 Shed the oldest frame
      summary: Bound every relay queue at 256 frames and drop the oldest frame when one is full.
      commits: a1b2c3d e4f5a6b
      approval: approved 2027-01-12 by Dana Reyes (feedback fb-relay-1)
    - spec: specs/Relay-Glossary.md
      summary: Define backpressure and shedding.
      commits: 9f8e7d6
      approval: editorial

*** Verification
    - test_name: test_queue_bound_holds
      file: tests/test_queue.py
      description: A queue never holds more than its limit.
      status: passing
    - test_name: test_oldest_frame_is_shed
      file: tests/test_queue.py
      description: A full queue drops its oldest frame and counts it.
      status: passing 2027-01-12 (review) at e4f5a6b

*** Implementation Details
    The queue keeps its frames in arrival order:
    - =RelayQueue.push= drops the oldest frame when the queue is full.
    - =RelayQueue.shed= counts the frames dropped.

    The backlog of a slow ground station is a separate structure.

*** Key Source Files
    - =src/relay/queue.py= — the bounded queue and its shedding.
    - =tests/test_queue.py= — the queue's tests.
    - =src/relay/flow.py= — flow control towards the ground stations.

** RB-M2: Report queue depth and slow stations
   :PROPERTIES:
   :status: in_progress
   :END:

*** Spec Changes
    - spec: specs/Relay-Metrics.md
      sections: Queue metrics
      summary: Name the queue-depth metric and its labels.
      commits: 0c1d2e3
      approval: pending
    - spec: specs/Relay-Ports.md
      summary: The metrics port moves to 9464.
      commits: 1d2e3f4
      approval: pending
    - spec: specs/Relay-Retention.md
      summary: Keep shed counts for seven days.
      commits: 2e3f4a5
      approval: approved 2027-01-13 by Sam Okafor (relayed by relay-manager)

*** Verification
    - test_name: test_depth_metric_reports_each_queue
      file: tests/test_metrics.py
      description: Every queue reports its depth.
      status: failing
    - test_name: test_slow_station_is_told_to_slow_down
      file: tests/test_flow.py
      description: A station that falls behind gets a slow-down frame.
      status: pending

*** Implementation Details
    The depth gauge is read when the metrics endpoint is scraped.

*** Key Source Files
    - =src/relay/metrics.py= — the gauges.

** RB-M3: Document the operator runbook
   :PROPERTIES:
   :status: planned
   :END:

*** Verification
    - test_name: test_runbook_links_resolve
      file: tests/test_docs.py
      description: Every link in the runbook resolves.
      status: pending
"""

  RelayCommitted* = """diff --git a/AGENTS.md b/AGENTS.md
index 1111111..2222222 100644
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -3,2 +3,3 @@
 ## Testing
 Run `just test` before every push.
+Run `just test-relay` when a change touches `src/relay/`.
diff --git a/specs/Relay-Backpressure.md b/specs/Relay-Backpressure.md
index 3333333..4444444 100644
--- a/specs/Relay-Backpressure.md
+++ b/specs/Relay-Backpressure.md
@@ -10,4 +10,8 @@ The relay forwards telemetry frames from the probes to the ground stations.
 ### RELAY-AREQ2 Bounded queues
-Every relay queue holds at most 512 frames.
+Every relay queue holds at most 256 frames, and says when it is full.
 ### RELAY-AREQ3 Ordered delivery
 Frames of one probe arrive in the order they were sent.
+### RELAY-AREQ4 Shed the oldest frame
+When a queue is full, the relay drops its oldest frame and counts it.
+### Flow control
+A ground station that falls behind is told to slow down.
diff --git a/specs/Relay-Metrics.md b/specs/Relay-Metrics.md
index 5555555..6666666 100644
--- a/specs/Relay-Metrics.md
+++ b/specs/Relay-Metrics.md
@@ -1,2 +1,3 @@
 # Relay metrics
 - `relay_frames_forwarded`: frames sent on.
+- `relay_queue_depth`: frames waiting, per queue.
diff --git a/src/relay/queue.py b/src/relay/queue.py
index 7777777..8888888 100644
--- a/src/relay/queue.py
+++ b/src/relay/queue.py
@@ -1,4 +1,6 @@
 class RelayQueue:
-    def __init__(self, limit=512):
+    def __init__(self, limit=256):
         self.limit = limit
+        self.shed = 0
         self.frames = []
+    # A full queue sheds its oldest frame.
diff --git a/src/relay/buffer.py b/src/relay/backlog.py
similarity index 88%
rename from src/relay/buffer.py
rename to src/relay/backlog.py
index 9999999..aaaaaaa 100644
--- a/src/relay/buffer.py
+++ b/src/relay/backlog.py
@@ -1,2 +1,2 @@
-class Buffer:
+class Backlog:
     # Frames a ground station has not taken yet.
diff --git a/src/relay/old_buffer.py b/src/relay/old_buffer.py
deleted file mode 100644
index bbbbbbb..0000000
--- a/src/relay/old_buffer.py
+++ /dev/null
@@ -1,2 +0,0 @@
-# The relay's first buffer, kept for one release.
-BUFFER_LIMIT = 512
diff --git a/docs/backpressure.png b/docs/backpressure.png
new file mode 100644
index 0000000..ccccccc
Binary files /dev/null and b/docs/backpressure.png differ
diff --git a/src/relay/transports/websocket/framing/compression/deflate/window/encoder.py b/src/relay/transports/websocket/framing/compression/deflate/window/encoder.py
new file mode 100644
index 0000000..ddddddd
--- /dev/null
+++ b/src/relay/transports/websocket/framing/compression/deflate/window/encoder.py
@@ -0,0 +1,2 @@
+def encode(frame):
+    return frame
"""

  RelayUncommitted* = """diff --git a/src/relay/queue.py b/src/relay/queue.py
index 8888888..9999990 100644
--- a/src/relay/queue.py
+++ b/src/relay/queue.py
@@ -6,1 +6,3 @@
     # A full queue sheds its oldest frame.
+    def push(self, frame):
+        self.frames.append(frame)
diff --git a/tests/test_queue.py b/tests/test_queue.py
new file mode 100644
index 0000000..eeeeeee
--- /dev/null
+++ b/tests/test_queue.py
@@ -0,0 +1,3 @@
+def test_full_queue_sheds_oldest():
+    q = RelayQueue(limit=1)
+    assert q.limit == 1
"""

  MalformedPlan* = """
#+TITLE: Relay Backpressure Milestones

* Milestones

** RB-M4: Records that cannot approve
   :PROPERTIES:
   :status: in_progress
   :END:

*** Spec Changes
    - spec: specs/Relay-Ports.md
      summary:
      commits: 3f4a5b6
      approval: approved 2027-01-14 by Dana Reyes (feedback fb-relay-9)
    - spec: specs/Relay-Retention.md
      summary: Keep shed counts for thirty days.
      commits: 4a5b6c7
      approval: approved 2027-02-30 by Dana Reyes (feedback fb-relay-10)
    - spec: specs/Relay-Metrics.md
      summary: Add the shed-rate metric.
      commits: 5b6c7d8
      approval: approved 2027-01-14 by  (feedback fb-relay-11)
    - =specs/Relay-Legacy.md= — approved in chat by the operator; the old free-text form.
"""

  NoSpecChangesPlan* = """
#+TITLE: Relay Backpressure Milestones

* Milestones

** RB-M2: Report queue depth and slow stations
   :PROPERTIES:
   :status: in_progress
   :END:

*** Verification
    - test_name: test_depth_metric_reports_each_queue
      file: tests/test_metrics.py
      description: Every queue reports its depth.
      status: failing
    - test_name: test_slow_station_is_told_to_slow_down
      file: tests/test_flow.py
      description: A station that falls behind gets a slow-down frame.
      status: pending

*** Key Source Files
    - =src/relay/queue.py= — the bounded queue and its shedding.
"""

  CodeOnlyDiff* = """diff --git a/src/relay/queue.py b/src/relay/queue.py
index 7777777..8888888 100644
--- a/src/relay/queue.py
+++ b/src/relay/queue.py
@@ -1,2 +1,3 @@
 class RelayQueue:
-    def __init__(self, limit=512):
+    def __init__(self, limit=256):
+        self.shed = 0
"""

  EmptyPlan* = """
#+TITLE: Relay Backpressure Milestones

* Milestones

** RB-M3: Document the operator runbook
   :PROPERTIES:
   :status: planned
   :END:
"""

  ChangesFixtureNames* = ["populated", "staged", "malformed", "all-passing",
                          "all-pending", "no-plan", "no-spec-changes", "code-long",
                          "empty", "loading", "error"]
    ## Every Changes story's fixture.

  ChangesErrorText* = "the review record could not be read: " &
    "GET /api/v1/tasks/relay-backpressure/review-record answered 503"

proc relayRecord*(text = RelayPlan): ReviewRecord =
  parseReviewRecord(RelayPlanPath, text)

proc relayChange*(): ChangeDiff =
  ## The change relative to the merge base: the committed diff and the
  ## uncommitted one, joined.
  mergeBaseRelative(parseUnifiedDiff(RelayCommitted),
                    parseUnifiedDiff(RelayUncommitted, coUncommitted))

proc longDiff*(files: int): ChangeDiff =
  ## A change of `files` files under deep paths, each `+2 −1`.
  var text = ""
  for i in 1 .. files:
    let path = "src/relay/stations/region-" & $(i mod 7) & "/site-" & $i &
      "/adapters/telemetry/frames/decoder_" & $i & ".py"
    text.add "diff --git a/" & path & " b/" & path & "\n" &
      "index 1234567..89abcde 100644\n--- a/" & path & "\n+++ b/" & path & "\n" &
      "@@ -1,1 +1,2 @@\n-LIMIT = 512\n+LIMIT = 256\n+SHED = True\n"
  parseUnifiedDiff(text)

proc withPlan(source: ScriptedActionSource; record: ReviewRecord;
              requests: seq[SpecApprovalRequest] = @[]) =
  source.reviews.add (RelayTaskId, TaskReview(record: record, hasPlan: true,
                                              approvalRequests: requests))

proc relayScope*(): ReviewScope =
  ReviewScope(taskId: RelayTaskId, sessionId: RelaySessionId)

proc relayRequests*(): seq[SpecApprovalRequest] =
  @[SpecApprovalRequest(milestoneId: "RB-M2", spec: "specs/Relay-Metrics.md",
                        feedbackId: RelayApprovalRequest)]

proc populatedChangesSource*(label = "invented change: relay backpressure"): ScriptedActionSource =
  ## The populated change: the plan, its approval request, and the change
  ## against the merge base and as the session's own diff.
  result = newScriptedActionSource(label)
  result.withPlan(relayRecord(), relayRequests())
  let bases = @[SinceMain, SessionChanges]
  result.addDiff(RelaySessionId, SinceMain, relayChange(), bases)
  result.addDiff(RelaySessionId, SessionChanges,
                 parseUnifiedDiff(RelayUncommitted, coUncommitted), bases)

proc changesFixture*(name: string): AgentHarborDataSource =
  ## The source of the Changes story `name` (`ChangesFixtureNames`). Raises
  ## `ValueError` for an unknown name.
  case name
  of "populated":
    populatedChangesSource()
  of "staged":
    let s = populatedChangesSource()
    s.reviews[0][1].record.stagedCards = @[
      TierCard(tier: stRequirement, path: "specs/Relay-Backpressure.md",
               requirement: "RELAY-AREQ5",
               heading: "RELAY-AREQ5 Tell the probe when frames are shed",
               change: rcAdded, origin: "operator-distilled", staged: true),
      TierCard(tier: stGovernance, path: ".ah/autonomy.md", change: rcModified,
               origin: "operator-distilled", staged: true)]
    s
  of "malformed":
    let s = newScriptedActionSource("invented change: records that cannot approve")
    s.withPlan(relayRecord(MalformedPlan))
    s.addDiff(RelaySessionId, SinceMain, relayChange())
    s
  of "all-passing", "all-pending":
    let s = populatedChangesSource()
    let status = if name == "all-passing": "passing" else: "pending"
    for m in s.reviews[0][1].record.milestones.mitems:
      for v in m.verifications.mitems:
        v.rawStatus = status
        let parsed = verificationStatusOf(status)
        v.status = parsed.status
        v.annotation = parsed.annotation
    s
  of "no-plan":
    let s = newScriptedActionSource("invented change: a task with no plan")
    s.addDiff(RelaySessionId, SinceMain, relayChange())
    s
  of "no-spec-changes":
    let s = newScriptedActionSource("invented change: code only")
    s.withPlan(relayRecord(NoSpecChangesPlan))
    s.addDiff(RelaySessionId, SinceMain, parseUnifiedDiff(CodeOnlyDiff))
    s
  of "code-long":
    let s = newScriptedActionSource("invented change: three hundred files")
    s.withPlan(relayRecord())
    s.addDiff(RelaySessionId, SinceMain, longDiff(300))
    s
  of "empty":
    let s = newScriptedActionSource("invented change: nothing changed")
    s.withPlan(relayRecord(EmptyPlan))
    s.addDiff(RelaySessionId, SinceMain, ChangeDiff())
    s
  of "loading": newPendingDataSource()
  of "error": newFailingDataSource(ChangesErrorText)
  else: raise newException(ValueError, "no Changes fixture named " & name)

proc describe*(diff: ChangeDiff): seq[string] =
  ## One line per file (`M src/relay/queue.py +4 −1 both`), for tests and
  ## a story's record.
  for f in diff.files:
    result.add $f.status & " " & (if f.oldPath.len > 0: f.oldPath & " -> " else: "") &
      f.path & " " & countsText(f.added, f.removed) & " " & $f.origin &
      (if f.binary: " binary" else: "")
