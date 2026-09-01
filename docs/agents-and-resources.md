# Agents and published resources

## Give an agent access to a journal

An agent started inside a journal inherits `TJ_JOURNAL`, `TJ_HOME`, `TJ`, and
`TJCTL`. It can inspect recent work with small, explicit reads:

```sh
tj hist
tj cat --tail 40 @42
tj cat @42/cmd @42/rc
```

The repository includes [an agent skill](../skill/SKILL.md) that explains this
workflow. Install or link it using the mechanism supported by the agent.

For Claude Code, a narrow permission rule can allow journal reads:

```json
{
  "permissions": {
    "allow": ["Bash(tj *)", "Bash(tjctl ls)"]
  }
}
```

The literal `tj` and `tjctl` commands must be on `PATH` for those rules to
match. A rule for `tj` does not automatically authorize arbitrary pipelines.

Journals record activity, not intent. Tell the agent the goal and use the
journal to supply commands and results that already exist.

## Publish fenced agent output

`tj-fence` passes an agent response through unchanged and publishes fenced code
blocks as resources:

```sh
agent-command "create a CSV and a script" | tj-fence
tj cat @-/files/1.csv
tj cat @-/files/2.sh
```

The resource MIME type is derived from the fence language. Publication happens
in the wrapper; the model does not need to emit terminal control sequences.

## Publish resources directly

A cooperating terminal program may mark spans of ordinary output as named
resources. The output remains visible and is also available below the entry,
for example `@ENTRY/files/data.csv`.

See the [OSC SLOT protocol](osc-5107.md) for message framing, path validation,
noout regions, and binary-data limits.
