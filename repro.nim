## Reprobuild project file for nim-agents-isonim-viewmodels.
##
## A cross-repo consumer modelled on ``nim-agents/repro.nim``: the sources
## ``import`` ``nim_agents`` (which re-exports ``nim_acp``,
## ``nim_agent_harbor`` and ``nim_everywhere``) and ``isonim``. Naming each
## sibling in ``uses:`` builds it from source and threads its ``library``
## ``src/`` root onto ``nim c --path:`` (SC-11 develop mode), replacing the
## ``Justfile``'s ``--path:../<sibling>/src`` flags.
##
## Tests follow the two-edge template of ``reprobuild-specs/Package-Model.md``
## §"The test template": a BUILD edge per test file collected into
## ``test-builds`` and an EXECUTE edge collected into ``test``.
##
## **The lists below are the Justfile's, entry for entry.** ``repro test`` and
## ``just test`` run the same suites, and ``repro build test-builds`` compiles
## every module ``just build`` does (plus the ``-d:nodejs`` compiles the JS
## tests run), per codetracer-pm ``spec/Repo-Requirements.md`` §2.8.1:
##
##   * ``viewmodelTests`` is ``build-native`` / ``test-native``;
##   * ``viewmodelJsBuildStems`` is ``build-js``: compiled for the browser
##     target (no ``-d:nodejs``) and never run, collected into ``js-build``;
##   * ``viewmodelJsTestStems`` is ``test-js``: compiled with ``-d:nodejs``
##     (what ``nim js -r`` adds, and what makes a failing ``unittest`` exit
##     non-zero under ``node``) and run under ``node``, collected into
##     ``js-test-builds`` / ``js-test``.
##
## The JS halves also join ``test-builds`` / ``test``, as the Justfile's
## ``build`` and ``test`` span both back-ends.
## ``tests/test_repro_collections_match_justfile.nim`` fails when a module is
## in one file and not the other, or in ``tests/`` and in neither; add a new
## suite to both.
##
## ``tools/nim-js-test-gate.sh`` (``just test-js``) also greps the log for
## failure sentinels and requires an ``[OK]`` line. The graph keys on
## ``node``'s exit status instead, so a JS module that registers no test at
## all passes here and fails there; the script stays authoritative for
## ``just test-js``.

import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import ct_test_nim_unittest

const viewmodelTests = @[
  "tests/test_activity_vm.nim",
  "tests/test_agent_harbor_fleet_vm.nim",
  "tests/test_live_source.nim",
  "tests/test_host_fed_source.nim",
  "tests/test_node_follower.nim",
  "tests/test_agent_harbor_sessions_vm.nim",
  "tests/test_session_tabs_opened.nim",
  "tests/test_progress_pie.nim",
  "tests/test_playback.nim",
  "tests/test_session_timeline_vm.nim",
  "tests/test_changes_vm.nim",
  "tests/test_inbox_vm.nim",
  "tests/test_inbox_item_vm.nim",
  "tests/test_omnibox_composer_vm.nim",
  "tests/test_result_commands_vm.nim",
  "tests/test_suggested_actions_vm.nim",
  "tests/test_test_runs_vm.nim",
  "tests/test_trace_opener_vm.nim",
  "tests/test_control_center_vm.nim",
  "tests/test_agent_workspace_vm.nim",
  "tests/test_agent_activity_vm.nim",
  "tests/test_nimcache_is_worktree_local.nim",
  "tests/test_fixture_set_rebuilds_on_switch.nim",
  "tests/test_repro_collections_match_justfile.nim",
]

const viewmodelJsBuildStems = @[
  "test_activity_vm", "test_agent_harbor_fleet_vm",
  "test_host_fed_source",
  "test_agent_harbor_sessions_vm", "test_session_tabs_opened",
  "test_progress_pie", "test_playback",
  "test_session_timeline_vm", "test_changes_vm", "test_inbox_vm",
  "test_inbox_item_vm", "test_omnibox_composer_vm",
  "test_result_commands_vm", "test_suggested_actions_vm",
  "test_test_runs_vm", "test_trace_opener_vm", "test_control_center_vm",
  "test_agent_workspace_vm", "test_agent_activity_vm",
]

const viewmodelJsTestStems = @[
  "test_activity_vm", "test_agent_harbor_fleet_vm",
  "test_host_fed_source",
  "test_agent_harbor_sessions_vm", "test_session_tabs_opened",
  "test_progress_pie", "test_playback",
  "test_session_timeline_vm", "test_changes_vm", "test_inbox_vm",
  "test_inbox_item_vm", "test_omnibox_composer_vm",
  "test_result_commands_vm", "test_suggested_actions_vm",
  "test_test_runs_vm", "test_trace_opener_vm", "test_control_center_vm",
  "test_agent_workspace_vm", "test_agent_activity_vm",
]

package nim_agents_isonim_viewmodels:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning "path"

  uses:
    "nim >=2.0"
    "gcc >=12"
    # Runs the ``nim js`` output of the JS test matrix (``node`` typed tool).
    "node >=20"

    "nim-acp"
    "nim-agent-harbor"
    "nim-everywhere"
    "nim-agents"
    "isonim"

  library nim_agents_isonim_viewmodels

  build:
    # Inputs every test compile reads besides its own module: the sources
    # and the Agent Harbor fixtures the fixture source embeds at compile time
    # (``staticRead`` of ``fixtures/agent-harbor/``).
    const testInputs = @["src", "fixtures", "nim_agents_isonim_viewmodels.nimble"]
    # The collection guard alone also reads ``Justfile`` and ``repro.nim``
    # (``staticRead``) and lists ``tests/`` at compile time. Only its edge
    # names them, so editing the Justfile, or ``just test`` writing its
    # binaries into ``tests/``, does not invalidate every other compile.
    const guardStem = "test_repro_collections_match_justfile"
    const guardInputs = @["Justfile", "repro.nim", "tests"]

    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    for source in viewmodelTests:
      var start = 0
      for i in 0 ..< source.len:
        if source[i] == '/': start = i + 1
      let stem = source[start ..< source.len - ".nim".len]
      let edge = buildNimUnittest.build(
        source = source,
        binary = "build/test-bin/" & stem,
        paths = @["src"],
        actionId = "nim_agents_isonim_viewmodels.test_build." & stem,
        extraInputs =
          if stem == guardStem: testInputs & guardInputs
          else: testInputs)
      testBuildActions.add(edge.action)
      testExecuteActions.add(edge.testBinary.run(
        actionId = "nim_agents_isonim_viewmodels.test_execute." & stem,
        registerImplicitName = false))

    # --- JavaScript back-end matrix ----------------------------------------
    var jsBuildActions: seq[BuildActionDef] = @[]
    for stem in viewmodelJsBuildStems:
      jsBuildActions.add(nim.js(
        source = "tests/" & stem & ".nim",
        # ``.browser.js``: the implicit target name is the output basename,
        # and the JS test edges below emit ``<stem>.js`` for the same stems.
        output = "build/js/" & stem & ".browser.js",
        paths = @["src"],
        actionId = "nim_agents_isonim_viewmodels.js_build." & stem,
        extraInputs = testInputs))

    var jsTestBuildActions: seq[BuildActionDef] = @[]
    var jsTestExecuteActions: seq[BuildActionDef] = @[]
    for stem in viewmodelJsTestStems:
      let jsOut = "build/js-test/" & stem & ".js"
      let jsTestBuildEdge = nim.js(
        source = "tests/" & stem & ".nim",
        output = jsOut,
        defines = @["nodejs"],
        paths = @["src"],
        actionId = "nim_agents_isonim_viewmodels.js_test_build." & stem,
        extraInputs = testInputs)
      jsTestBuildActions.add(jsTestBuildEdge)
      jsTestExecuteActions.add(node(
        args = @[jsOut],
        actionId = "nim_agents_isonim_viewmodels.js_test_execute." & stem,
        after = @[jsTestBuildEdge],
        extraInputs = @[jsOut]))

    discard collect("js-build", jsBuildActions)
    discard collect("js-test-builds", jsTestBuildActions)
    discard collect("js-test", jsTestExecuteActions)
    testBuildActions.add(jsBuildActions)
    testBuildActions.add(jsTestBuildActions)
    testExecuteActions.add(jsTestExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
