## Prints which Agent Harbor fixture set this binary embedded.
## `tests/test_fixture_set_rebuilds_on_switch.nim` compiles and runs it.
import nim_agents_isonim_viewmodels/agent_harbor/fixture_source

echo "fixture-set=", AgentHarborFixtureSet
echo "fixture-root=", AgentHarborFixtureRoot
