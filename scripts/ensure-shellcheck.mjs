import crypto from 'node:crypto'
import fs from 'node:fs'
import https from 'node:https'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const VERSION = '0.11.0'
const RELEASE = `https://github.com/koalaman/shellcheck/releases/download/v${VERSION}`
const PLATFORMS = {
  'darwin-arm64': {
    asset: `shellcheck-v${VERSION}.darwin.aarch64.tar.gz`,
    sha256: '339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f',
  },
  'darwin-x64': {
    asset: `shellcheck-v${VERSION}.darwin.x86_64.tar.gz`,
    sha256: 'c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51',
  },
  'linux-arm64': {
    asset: `shellcheck-v${VERSION}.linux.aarch64.tar.gz`,
    sha256: '68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc',
  },
  'linux-x64': {
    asset: `shellcheck-v${VERSION}.linux.x86_64.tar.gz`,
    sha256: 'b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6',
  },
}

export function shellcheckPath() {
  return path.join(ROOT, '.cache', 'shellcheck', VERSION, `${process.platform}-${process.arch}`, 'shellcheck')
}

function download(url, destination, redirects = 5) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume()
        if (redirects === 0) {
          reject(new Error(`Too many redirects downloading ${url}`))
          return
        }
        resolve(download(new URL(response.headers.location, url), destination, redirects - 1))
        return
      }
      if (response.statusCode !== 200) {
        response.resume()
        reject(new Error(`Download failed with HTTP ${response.statusCode}: ${url}`))
        return
      }
      const output = fs.createWriteStream(destination, { flags: 'wx' })
      response.pipe(output)
      output.on('finish', () => output.close(resolve))
      output.on('error', reject)
    })
    request.on('error', reject)
  })
}

export async function ensureShellcheck() {
  const binary = shellcheckPath()
  if (fs.existsSync(binary)) return binary

  const platform = PLATFORMS[`${process.platform}-${process.arch}`]
  if (!platform) {
    throw new Error(`ShellCheck is not bundled for ${process.platform}-${process.arch}`)
  }

  const destination = path.dirname(binary)
  const archive = path.join(destination, platform.asset)
  fs.mkdirSync(destination, { recursive: true })

  try {
    await download(`${RELEASE}/${platform.asset}`, archive)
    const digest = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex')
    if (digest !== platform.sha256) {
      throw new Error(`ShellCheck archive checksum mismatch: expected ${platform.sha256}, got ${digest}`)
    }
    execFileSync('tar', [
      '-xzf', archive,
      '--strip-components=1',
      '-C', destination,
      `shellcheck-v${VERSION}/shellcheck`,
    ])
    fs.chmodSync(binary, 0o755)
  } finally {
    fs.rmSync(archive, { force: true })
  }
  return binary
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const binary = await ensureShellcheck()
  console.log(`ShellCheck ${VERSION}: ${path.relative(ROOT, binary)}`)
}
