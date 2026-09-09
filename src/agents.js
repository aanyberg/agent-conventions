import fs from 'node:fs'
import path from 'node:path'

const NAME = /^conventions-[a-z0-9]+(?:-[a-z0-9]+)*$/
const CAPABILITIES = new Set(['read', 'search', 'shell', 'write', 'ask'])
const ACCESS = new Set(['read-only', 'workspace-write'])
const MODEL_TIERS = new Set(['fast', 'balanced', 'deep'])
const EFFORTS = new Set(['low', 'medium', 'high'])

function parseValue(raw) {
  const value = raw.trim()
  if (value.startsWith('[') && value.endsWith(']')) {
    return value.slice(1, -1).split(',').map((item) => item.trim()).filter(Boolean)
  }
  if (/^\d+$/.test(value)) return Number(value)
  return value
}

export function parseCanonicalAgent(text, source = '<agent>') {
  if (!text.startsWith('---\n')) throw new Error(`${source}: missing frontmatter`)
  const end = text.indexOf('\n---\n', 4)
  if (end === -1) throw new Error(`${source}: unterminated frontmatter`)

  const metadata = {}
  for (const line of text.slice(4, end).split('\n')) {
    const match = /^([a-z][a-z-]*):\s*(.+)$/.exec(line)
    if (!match) throw new Error(`${source}: unsupported frontmatter line ${JSON.stringify(line)}`)
    metadata[match[1]] = parseValue(match[2])
  }

  const required = ['name', 'description', 'capabilities', 'access', 'model-tier', 'effort', 'max-turns']
  const unknown = Object.keys(metadata).filter((key) => !required.includes(key))
  if (unknown.length) throw new Error(`${source}: unknown frontmatter fields ${unknown.join(', ')}`)
  const missing = required.filter((key) => metadata[key] === undefined)
  if (missing.length) throw new Error(`${source}: missing ${missing.join(', ')}`)
  if (!NAME.test(metadata.name)) throw new Error(`${source}: invalid package-prefixed name ${metadata.name}`)
  if (!Array.isArray(metadata.capabilities) || metadata.capabilities.length === 0 ||
      metadata.capabilities.some((item) => !CAPABILITIES.has(item))) {
    throw new Error(`${source}: capabilities must be a JSON array of known capability names`)
  }
  if (!ACCESS.has(metadata.access)) throw new Error(`${source}: invalid access ${metadata.access}`)
  if (!MODEL_TIERS.has(metadata['model-tier'])) throw new Error(`${source}: invalid model tier ${metadata['model-tier']}`)
  if (!EFFORTS.has(metadata.effort)) throw new Error(`${source}: invalid effort ${metadata.effort}`)
  if (!Number.isInteger(metadata['max-turns']) || metadata['max-turns'] < 1) {
    throw new Error(`${source}: max-turns must be a positive integer`)
  }
  if (metadata.access === 'read-only' && metadata.capabilities.includes('write')) {
    throw new Error(`${source}: read-only agents cannot request write capability`)
  }

  const body = text.slice(end + 5).trim()
  if (!body) throw new Error(`${source}: body is empty`)
  return { ...metadata, body: body + '\n', source }
}

export function bundledAgents(packageRoot) {
  const dir = path.join(packageRoot, 'agent-sources')
  return fs.readdirSync(dir)
    .filter((name) => name.endsWith('.md'))
    .map((filename) => {
      const source = path.join(dir, filename)
      const agent = parseCanonicalAgent(fs.readFileSync(source, 'utf8'), source)
      if (`${agent.name}.md` !== filename) {
        throw new Error(`${source}: name must match filename`)
      }
      return agent
    })
    .sort((a, b) => a.name.localeCompare(b.name))
}

const TOOL_MAP = {
  'claude-code': {
    read: ['Read'], search: ['Grep', 'Glob'], shell: ['Bash'],
    write: ['Edit', 'Write'], ask: ['AskUserQuestion'],
  },
  'github-copilot': {
    read: ['read'], search: ['search'], shell: ['execute'], write: ['edit'], ask: [],
  },
  'gemini-cli': {
    read: ['read_file', 'read_many_files'], search: ['grep_search', 'glob'],
    shell: ['run_shell_command'], write: ['replace', 'write_file'], ask: [],
  },
}

function toolsFor(agent, provider) {
  const mapping = TOOL_MAP[provider]
  if (!mapping) return []
  return [...new Set(agent.capabilities.flatMap((capability) => mapping[capability] ?? []))]
}

function yamlHeader(lines, body) {
  return `---\n${lines.join('\n')}\n---\n\n${body}`
}

function yamlString(value) {
  return JSON.stringify(String(value))
}

// Preserve physical Markdown lines while escaping TOML basic-string syntax.
function tomlMultilineString(value) {
  let escaped = ''
  for (const char of String(value)) {
    if (char === '\\') escaped += '\\\\'
    else if (char === '"') escaped += '\\"'
    else if (char === '\b') escaped += '\\b'
    else if (char === '\t') escaped += '\\t'
    else if (char === '\n') escaped += '\n'
    else if (char === '\f') escaped += '\\f'
    else if (char === '\r') escaped += '\\r'
    else {
      const code = char.codePointAt(0)
      escaped += code < 0x20 || code === 0x7f
        ? `\\u${code.toString(16).padStart(4, '0')}`
        : char
    }
  }
  return `"""\n${escaped}"""`
}

function renderClaude(agent) {
  const models = { fast: 'haiku', balanced: 'sonnet', deep: 'opus' }
  const tools = [...toolsFor(agent, 'claude-code'), 'Skill']
  return yamlHeader([
    `name: ${agent.name}`,
    `description: ${yamlString(agent.description)}`,
    `tools: ${tools.join(', ')}`,
    `model: ${models[agent['model-tier']]}`,
    `effort: ${agent.effort}`,
    `maxTurns: ${agent['max-turns']}`,
    'permissionMode: default',
  ], agent.body)
}

function renderCodex(agent) {
  return [
    `name = ${JSON.stringify(agent.name)}`,
    `description = ${JSON.stringify(agent.description)}`,
    `sandbox_mode = ${JSON.stringify(agent.access)}`,
    `model_reasoning_effort = ${JSON.stringify(agent.effort)}`,
    `developer_instructions = ${tomlMultilineString(agent.body)}`,
    '',
  ].join('\n')
}

function renderCopilot(agent) {
  const tools = toolsFor(agent, 'github-copilot').map(yamlString).join(', ')
  return yamlHeader([
    `name: ${agent.name}`,
    `description: ${yamlString(agent.description)}`,
    `tools: [${tools}]`,
  ], agent.body)
}

function renderOpenCode(agent) {
  const writable = agent.access === 'workspace-write'
  return yamlHeader([
    `description: ${yamlString(agent.description)}`,
    'mode: subagent',
    'permission:',
    `  edit: ${writable ? 'allow' : 'deny'}`,
    `  bash: ${agent.capabilities.includes('shell') ? 'allow' : 'deny'}`,
    `  webfetch: deny`,
  ], agent.body)
}

function renderCursor(agent) {
  return yamlHeader([
    `name: ${agent.name}`,
    `description: ${yamlString(agent.description)}`,
    'model: inherit',
    `readonly: ${agent.access === 'read-only'}`,
    'is_background: false',
  ], agent.body)
}

function renderGemini(agent) {
  const tools = toolsFor(agent, 'gemini-cli')
  const lines = [
    `name: ${agent.name}`,
    `description: ${yamlString(agent.description)}`,
    'kind: local',
    'tools:',
    ...tools.map((tool) => `  - ${tool}`),
    `max_turns: ${agent['max-turns']}`,
  ]
  return yamlHeader(lines, agent.body)
}

const RENDERERS = {
  'claude-code': renderClaude,
  codex: renderCodex,
  'github-copilot': renderCopilot,
  opencode: renderOpenCode,
  cursor: renderCursor,
  'gemini-cli': renderGemini,
}

export function renderAgent(agent, provider) {
  const render = RENDERERS[provider]
  if (!render) throw new Error(`no agent renderer for ${provider}`)
  return render(agent)
}
