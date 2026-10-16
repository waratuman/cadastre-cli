# cadastre

The command-line client for [Cadastre](https://getcadastre.com)'s public API:
real-estate data (datasets, measures, metro profiles, screens and rankings;
everything except listings) in your terminal, your scripts and your AI
assistant.

```console
$ cadastre login
$ cadastre screen --min-pop 500k --max-unemployment 5.5 --max-power-price 10 --rtw-only --states TX,OK
$ cadastre rank --min-pop 250k --criterion unemployment_rate:2:lower --criterion population
$ cadastre mcp add claude-code
```

Status: beta, like the API (`/api/v1`). Written in Zig, one static binary, no
runtime dependencies.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/waratuman/cadastre-cli/main/install.sh | sh
```

> **Placeholder.** The GitHub repository (`github.com/waratuman/cadastre-cli`)
> does not exist yet, so neither does that URL nor the release downloads
> `install.sh` fetches (`.../releases/latest/download/cadastre-<arch>-<os>.tar.gz`).
> Until then, build from source (below), or run `zig build release` and point
> the installer at the result:
> `CADASTRE_RELEASES_URL=file://$PWD/zig-out/release sh install.sh`.

`install.sh` is POSIX sh. It detects the OS (Linux, macOS) and CPU (x86_64,
arm64), downloads the tarball and its `.sha256`, verifies the checksum, and
installs `cadastre` to `~/.local/bin` (`/usr/local/bin` as root). Set
`CADASTRE_INSTALL_DIR` to choose the directory and `CADASTRE_VERSION=v0.1.0`
to pin a release. It edits no shell profile; it says so when the directory is
not on your `PATH`. Windows: download `cadastre-x86_64-windows.tar.gz` from the
releases page.

## Sign in

```sh
cadastre login            # opens your browser; approve "Cadastre CLI" on the consent page
cadastre login --device   # no browser here (SSH, a container): type the code shown at getcadastre.com/oauth/device
cadastre login --key      # store an API key (Settings > API keys) instead; it is read from stdin
cadastre whoami
cadastre logout           # revokes the sign-in and deletes it from this machine
```

- **Browser** (default): OAuth 2.1 authorization code with PKCE (S256). The CLI
  listens on `http://127.0.0.1:<free port>/callback` for the redirect
  (RFC 8252), checks `state` and the issuer (`iss`, RFC 9207), and exchanges
  the code. `--no-browser` prints the URL instead of opening it (it must still
  be opened on the same machine).
- **Device** (`--device`, RFC 8628): for machines without a browser. Only enter
  a code you started yourself.
- **API key** (`--key`): paste it when asked (input hidden) or pipe it
  (`pbpaste | cadastre login --key`). Never pass a key as an argument (shell
  history, `ps`).
- **`CADASTRE_API_KEY`**: when set, it is used for every request instead of
  any saved sign-in. Handy in CI.

OAuth access tokens last an hour and are refreshed automatically; the server
rotates the refresh token on every use and the CLI saves the newest one at
once. A file lock stops two `cadastre` processes from refreshing at the same
moment (presenting a rotated refresh token twice makes the server revoke the
sign-in). A sign-in lasts at most 90 days; then `cadastre login` again.

`cadastre logout` revokes a browser or device sign-in on the server. For an API
key it only removes the key from this machine, since the key may be used
elsewhere; `cadastre logout --revoke` revokes the key too.

## Commands

| Command | What |
| --- | --- |
| `cadastre datasets [key]` | The datasets the API serves, or one with its measures |
| `cadastre measures [name] [--q text] [--geography msa\|county\|state] [--dataset key]` | Search the measures, or show one (how each geography's value is made) |
| `cadastre metros [--state TX] [--q text]` | The metropolitan statistical areas |
| `cadastre metro <ref>` | A metro's profile; `<ref>` is the CBSA code (`12420`), the slug or the id |
| `cadastre compare <ref>... [--measures a,b]` | Up to 25 metros side by side |
| `cadastre screen [requirements]` | The metros that pass your Requirements, with the funnel |
| `cadastre rank [requirements] --criterion ...` | Rank the metros on weighted criteria |
| `cadastre mcp add <client> [--write]` | Connect Claude Code, Codex, Cursor or VS Code |
| `cadastre docs [page]` | Open the docs (`cadastre docs api`, `cadastre docs rights`) |
| `cadastre login`, `logout`, `whoami`, `version`, `help [command]` | |

Paged lists take `--page` and `--per-page` (up to 500). `cadastre help
<command>` and `cadastre <command> --help` list every flag.

### Screening and ranking

`screen` and `rank` compute an answer on the server and save nothing. The
Requirement flags map one to one onto the API's request keys (the project
page's Requirements):

| Flag | API key | Meaning |
| --- | --- | --- |
| `--min-pop 250k\|500k\|1m` | `requirements.tier` | population at least (the three tiers the API screens on; `500000`, `1M` also accepted) |
| `--min-mfg-share 8` | `requirements.min_mfg_share` | manufacturing share of GDP, percent, at least |
| `--max-unemployment 5.5` | `requirements.max_unemployment` | unemployment rate, percent, at most |
| `--min-growth 2` | `requirements.min_growth` | five-year population growth, percent, at least |
| `--max-hazard 60` | `requirements.max_hazard` | FEMA National Risk Index, at most |
| `--max-power-price 10` (alias `--max-elec-price`) | `requirements.max_elec_price` | industrial electricity price, cents per kWh, at most |
| `--rtw-only` | `requirements.rtw_only` | only metros entirely in right-to-work states |
| `--states TX,OK` | `scope.states` | only metros partly in these states |

A Requirement whose data the API does not serve is refused with the API's
message (HTTP 422), never silently dropped.

`rank` adds criteria, each a catalog measure available for metros:

```sh
cadastre rank --min-pop 500k --states TX,OK,LA \
  --criterion unemployment_rate:2:lower \
  --criterion population:1:higher \
  --cutoff fema_nri_risk_index:gt:70 \
  --include-eliminated
```

- `--criterion measure[:weight[:higher|lower]]`, repeatable (20 at most):
  weight defaults to 1 (0 keeps it a gate only), direction to `higher`.
- `--cutoff measure:gt|gte|lt|lte:value` eliminates the metros for which it
  holds; it attaches to that measure's criterion, or adds a weight-0 one.
- `--include-eliminated` lists the eliminated metros with the reasons.
- `--limit n` caps the rows printed (default 50 for screen, 25 for rank; `0`
  for all). `--json` always returns everything.

## Output and attribution

Tables by default; `--json` prints the API's answer exactly as it came
(`{ data, meta?, attribution }`), for `jq` and for agents. `--no-color` (or
`NO_COLOR=1`) turns colour off; colour is only used on a terminal.

**Attribution is not optional.** Every data answer carries an `attribution`
array: each dataset's credit, licence, links, the notices and disclaimers the
publishers require, their conditions, and `retrieved_at` (when Cadastre last
retrieved the data). The CLI prints all of it below every table, and `--json`
keeps it in the output. Cadastre's [Terms](https://getcadastre.com/terms#api)
require you to carry these credits with the figures wherever you use them; see
[getcadastre.com/docs/rights](https://getcadastre.com/docs/rights). Values
marked `*` (`computed_by_cadastre` in JSON) are Cadastre's aggregates or
derivations of the publisher's figures, not figures the publisher printed.

No geometry is served (names and codes only), and parcel data is not part of
the API.

## Connect an AI assistant (MCP)

Cadastre runs a remote MCP server at `https://getcadastre.com/mcp`. The
assistant signs in through your browser on first use (OAuth); no API key is
written anywhere.

```sh
cadastre mcp                     # the server URL and the clients
cadastre mcp add claude-code     # prints the command and the config
cadastre mcp add cursor --write  # edits the config file for you
```

| Client | Printed command | `--write` edits |
| --- | --- | --- |
| `claude-code` | `claude mcp add --transport http --scope user cadastre https://getcadastre.com/mcp` | `./.mcp.json` (this project) |
| `codex` | `codex mcp add cadastre --url https://getcadastre.com/mcp`, then `codex mcp login cadastre` | `$CODEX_HOME/config.toml` (`~/.codex/config.toml`) |
| `cursor` | (none) | `~/.cursor/mcp.json` |
| `vscode` | `code --add-mcp '{"name":"cadastre","type":"http","url":"https://getcadastre.com/mcp"}'` | `./.vscode/mcp.json` (this workspace) |

Nothing is written without `--write`. With it, the existing file is copied to
`<file>.bak-<unix time>` first, only a `cadastre` entry is added, and a file
that already has a different `cadastre` entry, or is not plain JSON (comments),
is left alone with a message. `--base-url` changes the server URL
(`<base>/mcp`).

## Configuration

| Variable / flag | Default | What |
| --- | --- | --- |
| `--base-url`, `CADASTRE_BASE_URL` | `https://getcadastre.com` | The Cadastre server (e.g. `http://127.0.0.1:3000` for a local one) |
| `CADASTRE_API_KEY` | | An API key used instead of the saved sign-in |
| `CADASTRE_CLIENT_ID`, `login --client-id` | `01a1439d-5c60-7b25-bb0b-cae67bd361aa` | The OAuth client (getcadastre.com's Cadastre CLI client; a local server prints its own with `bin/rails oauth:cli_client`) |
| `CADASTRE_CREDENTIAL_STORE` | per platform | `keychain`, `secret-service` or `file` |
| `XDG_CONFIG_HOME` | `~/.config` | Where the credentials file and refresh lock live (`$XDG_CONFIG_HOME/cadastre/`) |
| `NO_COLOR`, `--no-color` | | No ANSI colour |
| `BROWSER` | the OS's opener | The program `login` and `docs` open URLs with |
| `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` | | Proxies |

### Where credentials are kept

One credential per server (base URL), so a local server's sign-in never
replaces production's.

- **macOS:** the login Keychain, a generic password with service
  `cadastre-cli` and account = the base URL (via `/usr/bin/security`; the secret
  is passed on stdin, never in argv). See it in Keychain Access under "Cadastre
  CLI".
- **Linux:** the Secret Service (GNOME Keyring, KWallet) via `secret-tool`
  (libsecret) when it is installed and a session bus answers.
- **Otherwise**, or with `CADASTRE_CREDENTIAL_STORE=file`: a JSON file readable
  only by you (mode 0600, in a 0700 directory) at
  `$XDG_CONFIG_HOME/cadastre/credentials.json` (`~/.config/cadastre/` when
  `XDG_CONFIG_HOME` is unset; `%APPDATA%\cadastre\` on Windows). It is written
  to a temporary file and renamed, so it is never half-written.

The CLI never prints a token or a key, and never sends one anywhere but the
server it signed in to.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | An error (the API refused the request, not found, network failure) |
| 2 | Usage: an unknown command or flag, a bad value |
| 3 | Not signed in, or the sign-in no longer works: run `cadastre login` |
| 4 | The account must accept Cadastre's current Terms: sign in at the site and accept them |
| 5 | Rate limited: the message gives the `Retry-After` seconds |

With `--json`, errors are printed to stderr as `{"error": "<code>", "message": "..."}`,
`error` being the API's own code (`not_found`, `invalid_request`, ...) when the
API sent one. A 401 is retried once after refreshing an OAuth token.

## Building from source

The CLI is written against **Zig 0.16.0 exactly** (`minimum_zig_version` in
`build.zig.zon`). Zig is pre-1.0 and its standard library changes between
releases (0.16 rewrote I/O around `std.Io`), so another Zig version will most
likely not build it; moving to a new Zig is a deliberate change of the pin, the
code and this README together.

```sh
zig build                          # debug build: zig-out/bin/cadastre
zig build -Doptimize=ReleaseSafe   # optimised, with safety checks
zig build run -- metros --state TX
zig build test --summary all       # unit tests
zig fmt --check build.zig build.zig.zon src tools   # or: zig build fmt
zig build release                  # every target, packaged (below)
```

`zig build release` cross-compiles, from any host, ReleaseSafe stripped
binaries for x86_64 and aarch64 Linux (musl, fully static: no libc at all),
x86_64 and aarch64 macOS (linking only libSystem), and x86_64 Windows, and
writes to `zig-out/release/` one `cadastre-<arch>-<os>.tar.gz` per target
(holding `cadastre/cadastre`), its `.sha256`, and `SHA256SUMS`. Packaging is
done by `tools/package.zig`, so it needs no tar, gzip or sha256sum. The binaries
are about 1.2 to 1.7 MB.

### Layout

| Path | What |
| --- | --- |
| `src/main.zig` | Entry point and command table |
| `src/commands.zig` | The commands and their tables |
| `src/api.zig` | API calls, refresh-and-retry, error messages and exit codes |
| `src/oauth.zig` | Discovery, browser (PKCE + loopback) and device login, refresh, revocation |
| `src/store.zig` | Credential storage (Keychain, Secret Service, file) |
| `src/requirements.zig` | Screen and rank flags to request bodies |
| `src/mcp.zig` | `cadastre mcp` |
| `src/render.zig` | Tables, numbers and the attribution block |
| `src/args.zig`, `src/url.zig`, `src/pkce.zig`, `src/http.zig` | Parsing, URLs, PKCE, HTTP |
| `test/fixtures/` | API answers recorded from a local Cadastre server (synthetic test data), used by the unit tests |
| `scripts/e2e.sh` | End-to-end run against a local server |
| `tools/package.zig` | Release packaging |

### Tests

`zig build test` runs the unit tests: argument parsing, the Requirement flag
mapping and request bodies, PKCE (the RFC 7636 test vector), URL and form
encoding, the authorization URL and redirect checks, decoding and rendering of
every recorded API answer (attribution included), credential encoding, and the
MCP config merges. They make no network calls.

`scripts/e2e.sh` drives the built CLI against a **local** Cadastre server (it
refuses to run against getcadastre.com): API-key login, every data command in
both output modes, the browser login with curl standing in for the browser,
a forced token refresh (checking the refresh token rotated), logout with
revocation, and the device login. It keeps credentials in a temporary file
store. See the script's header for the variables it needs (a user who has
accepted the Terms, an API key, and the client id `bin/rails oauth:cli_client`
prints).

### Releasing

`.github/workflows/release.yml` runs the tests on every push and, on a `v*` tag
matching `build.zig.zon`'s version, runs `zig build release` and publishes the
files as a GitHub release. It is a convenience: the same release can be made by
hand with `zig build release` and
`gh release create v0.1.0 zig-out/release/*`. The release files are not signed
yet (checksums only).

## Known limitations

- The browser login waits until the redirect arrives or you press Ctrl-C (the
  server's request expires after ten minutes).
- The Windows build compiles but has not been run; it stores credentials in the
  file.
- The x86_64 Linux binary cannot be run under Docker Desktop's Rosetta
  emulation on Apple silicon ("bss_size overflow"); it is for real x86_64
  Linux. The aarch64 Linux build runs in containers there.
- Measure values per region (`/api/v1/measures/{name}/values`) are not a
  command yet; use the API directly.

## License

TODO: the owner has not chosen a license yet. Until a `LICENSE` file is added,
no license is granted.
