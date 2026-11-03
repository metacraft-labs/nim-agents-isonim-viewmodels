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
## ``test-builds`` and an EXECUTE edge collected into ``test``. The JS target is
## a ``Justfile``-only concern, as in nim-agents.

import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import ct_test_nim_unittest

const viewmodelTests = @[
  "tests/test_activity_vm.nim",
  "tests/test_nimcache_is_worktree_local.nim",
]

package nim_agents_isonim_viewmodels:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning "path"

  uses:
    "nim >=2.0"
    "gcc >=12"

    "nim-acp"
    "nim-agent-harbor"
    "nim-everywhere"
    "nim-agents"
    "isonim"

  library nim_agents_isonim_viewmodels

  build:
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
        extraInputs = @["src", "nim_agents_isonim_viewmodels.nimble"])
      testBuildActions.add(edge.action)
      testExecuteActions.add(edge.testBinary.run(
        actionId = "nim_agents_isonim_viewmodels.test_execute." & stem,
        registerImplicitName = false))

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
