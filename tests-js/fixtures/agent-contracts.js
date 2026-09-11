export const PROVIDER_CONTRACTS = {
  'claude-code': {
    keys: ['name', 'description', 'tools', 'model', 'effort', 'maxTurns', 'permissionMode'],
    values: {
      model: ['haiku', 'sonnet', 'opus'],
      effort: ['low', 'medium', 'high'],
      permissionMode: ['default'],
    },
  },
  codex: {
    keys: ['name', 'description', 'sandbox_mode', 'model_reasoning_effort', 'developer_instructions'],
    values: {
      sandbox_mode: ['read-only', 'workspace-write'],
      model_reasoning_effort: ['low', 'medium', 'high'],
    },
  },
  'github-copilot': {
    keys: ['name', 'description', 'tools'],
  },
  opencode: {
    keys: ['description', 'mode', 'permission'],
    values: {
      mode: ['subagent'],
      'permission.edit': ['allow', 'deny'],
      'permission.bash': ['allow', 'deny'],
      'permission.webfetch': ['deny'],
    },
  },
  cursor: {
    keys: ['name', 'description', 'model', 'readonly', 'is_background'],
    values: {
      model: ['inherit'],
    },
  },
  'gemini-cli': {
    keys: ['name', 'description', 'kind', 'tools', 'max_turns'],
    values: {
      kind: ['local'],
    },
  },
}

export const INVALID_PROVIDER_FIXTURES = [
  ['claude-code', { model: 'unsupported' }, /model/],
  ['codex', { sandbox_mode: 'unsafe' }, /sandbox_mode/],
  ['github-copilot', { tools: 'read' }, /tools/],
  ['opencode', { permission: { edit: 'prompt', bash: 'allow', webfetch: 'deny' } }, /permission.edit/],
  ['cursor', { readonly: 'false' }, /readonly/],
  ['gemini-cli', { kind: 'remote', max_turns: 0 }, /kind/],
]
