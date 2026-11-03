# Agent Harbor fixtures (synthetic)

An invented fixture set in the shapes of the Agent Harbor wire types: a
fleet of sessions (`fleet/`), campaign plans (`plans/`), branch diffs
(`diffs/`), test runs (`tests/`) and scenario runs (`scenarios/`).
Every name, id, prompt, host and repository in it is made up.

`src/nim_agents_isonim_viewmodels/agent_harbor/fixture_source.nim` embeds
it when no captured fixture set is available to the build (its module
comment says how the set is chosen). Regenerate it from a CodeTracer
checkout beside this one:

```bash
node tools/agent-harbor-fixtures/synthesize.mjs
```

Do not edit these files by hand, and never copy captured data into them.
