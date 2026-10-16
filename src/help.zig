//! `cadastre help [command]` and `<command> --help`.
const std = @import("std");
const App = @import("App.zig");

const overview =
    \\cadastre: Cadastre's real-estate data from the command line
    \\(datasets, measures, metro profiles, screens and rankings; not listings).
    \\
    \\Usage: cadastre <command> [flags]
    \\
    \\Account
    \\  login                Sign in through the browser (--device, --key)
    \\  logout               Sign out and revoke the sign-in
    \\  whoami               Who the CLI acts as
    \\
    \\Data
    \\  datasets [key]       The datasets served, or one with its measures
    \\  measures [name]      Search the measures, or show one
    \\  metros               List the metropolitan areas
    \\  metro <ref>          A metro's profile (CBSA code, slug or id)
    \\  compare <ref>...     Metros side by side
    \\  screen               Metros that pass your Requirements
    \\  rank                 Rank metros on weighted criteria
    \\
    \\Assistants and docs
    \\  mcp add <client>     Connect Claude Code, Codex, Cursor or VS Code
    \\  docs [page]          Open the docs
    \\  version              Print the version
    \\
    \\Global flags
    \\  --json               Print the API's JSON answer (attribution included)
    \\  --no-color           No ANSI colour (also NO_COLOR=1)
    \\  --base-url <url>     Another Cadastre server (env CADASTRE_BASE_URL;
    \\                       default https://getcadastre.com)
    \\  -h, --help           Help for a command
    \\
    \\Every answer carries the credits of the data behind it, printed below the
    \\figures: keep them with the figures wherever you use them
    \\(https://getcadastre.com/terms#api, https://getcadastre.com/docs/rights).
    \\
    \\Run `cadastre help <command>` for a command's flags and examples.
    \\
;

const Topic = struct { name: []const u8, text: []const u8 };

const topics = [_]Topic{
    .{ .name = "login", .text =
    \\Usage: cadastre login [--device | --key] [--no-browser] [--client-id <id>]
    \\
    \\Signs in and saves the credential for this site (--base-url) in the
    \\macOS Keychain, the Secret Service on Linux, or a 0600 file.
    \\
    \\  (default)       Opens the browser; you approve Cadastre CLI on the
    \\                  consent page and the browser hands the code back to a
    \\                  listener on 127.0.0.1 (OAuth 2.1 with PKCE).
    \\  --no-browser    Print the sign-in URL instead of opening a browser
    \\                  (it must still be opened on this machine).
    \\  --device        For a machine with no browser (SSH, containers): shows
    \\                  a code to type at <site>/oauth/device on any device.
    \\  --key           Save an API key (Settings > API keys) instead, read from
    \\                  stdin: `cadastre login --key` asks for it (hidden), or
    \\                  `pbpaste | cadastre login --key`.
    \\  --client-id     The OAuth client to sign in as (env CADASTRE_CLIENT_ID;
    \\                  for a local server, the id `bin/rails oauth:cli_client`
    \\                  prints).
    \\
    \\CADASTRE_API_KEY, when set, is used instead of any saved sign-in.
    \\
    },
    .{ .name = "logout", .text =
    \\Usage: cadastre logout [--revoke]
    \\
    \\Removes the saved credential for this site. A browser or device sign-in
    \\is revoked on the server too. An API key is only removed from this
    \\machine unless you pass --revoke, which also revokes the key everywhere.
    \\
    },
    .{ .name = "whoami", .text =
    \\Usage: cadastre whoami [--json]
    \\
    \\The person, account and credential the CLI acts as, and where the
    \\credential comes from.
    \\
    },
    .{ .name = "datasets", .text =
    \\Usage: cadastre datasets [key] [--json]
    \\
    \\Lists the datasets the API serves (publisher, licence, vintages,
    \\geographies), or one dataset with its measures.
    \\
    \\Examples:
    \\  cadastre datasets
    \\  cadastre datasets acs
    \\
    },
    .{ .name = "measures", .text =
    \\Usage: cadastre measures [name] [--q <text>] [--geography msa|county|state]
    \\                        [--dataset <key>] [--page <n>] [--per-page <n>]
    \\
    \\Searches the measures (name, label, unit), or shows one: for each
    \\geography, how a value is made, whether Cadastre computed it, its
    \\vintages and how many regions have one.
    \\
    \\Examples:
    \\  cadastre measures --q unemployment
    \\  cadastre measures --geography county --dataset acs
    \\  cadastre measures unemployment_rate
    \\
    },
    .{ .name = "metros", .text =
    \\Usage: cadastre metros [--state <USPS>] [--q <text>] [--page <n>] [--per-page <n>]
    \\
    \\Lists the metropolitan statistical areas: CBSA code, name, states,
    \\right-to-work and population.
    \\
    \\Examples:
    \\  cadastre metros --state TX
    \\  cadastre metros --q austin
    \\
    },
    .{ .name = "metro", .text =
    \\Usage: cadastre metro <ref>
    \\
    \\A metro's profile: every measure served that it has a value for. <ref> is
    \\the five-digit CBSA code, the slug (us/tx/austin-round-rock-12420) or the
    \\id.
    \\
    \\Examples:
    \\  cadastre metro 12420
    \\  cadastre metro 12420 --json
    \\
    },
    .{ .name = "compare", .text =
    \\Usage: cadastre compare <ref> <ref>... [--measures a,b,...]
    \\
    \\Up to 25 metros side by side on up to 50 measures (default: the
    \\standard figures).
    \\
    \\Example:
    \\  cadastre compare 12420 46140 --measures population,unemployment_rate
    \\
    },
    .{ .name = "screen", .text =
    \\Usage: cadastre screen [requirements] [--limit <n>]
    \\
    \\The metros that pass your Requirements, with the funnel. Nothing is
    \\saved. Requirements (each optional):
    \\
    \\  --min-pop 250k|500k|1m     population at least (the API's three tiers)
    \\  --min-mfg-share <pct>      manufacturing share of GDP at least, percent
    \\  --max-unemployment <pct>   unemployment rate at most, percent
    \\  --min-growth <pct>         five-year population growth at least, percent
    \\  --max-hazard <n>           FEMA National Risk Index at most
    \\  --max-power-price <c/kWh>  industrial electricity price at most, cents
    \\                             (alias --max-elec-price)
    \\  --rtw-only                 only metros entirely in right-to-work states
    \\  --states TX,OK             only metros partly in these states
    \\  --limit <n>                rows to print (default 50; 0 for all)
    \\
    \\A Requirement whose data the API does not serve is refused (422).
    \\
    \\Example:
    \\  cadastre screen --min-pop 500k --max-unemployment 5.5 --max-power-price 10 --rtw-only --states TX,OK
    \\
    },
    .{ .name = "rank", .text =
    \\Usage: cadastre rank [requirements] --criterion <measure[:weight[:higher|lower]]>...
    \\                     [--cutoff <measure:gt|gte|lt|lte:value>]... [--include-eliminated] [--limit <n>]
    \\
    \\Ranks the metros that pass the Requirements (the flags of `cadastre
    \\screen`) on weighted criteria, by percentile score. Nothing is saved.
    \\
    \\  --criterion m:w:dir   a catalog measure (see `cadastre measures --geography msa`),
    \\                        its weight (default 1; 0 = gate only) and whether
    \\                        higher or lower is better (default higher). Repeatable, 20 at most.
    \\  --cutoff m:cmp:v      eliminate the metros whose m is gt/gte/lt/lte v.
    \\  --include-eliminated  list the eliminated metros too, with the reasons.
    \\  --limit <n>           rows to print (default 25; 0 for all)
    \\
    \\Example:
    \\  cadastre rank --min-pop 250k --criterion unemployment_rate:2:lower \
    \\    --criterion population:1:higher --cutoff fema_nri_risk_index:gt:80
    \\
    },
    .{ .name = "mcp", .text =
    \\Usage: cadastre mcp [list]
    \\       cadastre mcp add <claude-code|codex|cursor|vscode> [--write]
    \\
    \\Connects an AI assistant to Cadastre's remote MCP server (<site>/mcp).
    \\Prints the client's command (Cursor has none) and the config file
    \\alternative; with --write, edits the config file (backed up first):
    \\
    \\  claude-code  ./.mcp.json (this project)
    \\  codex        $CODEX_HOME/config.toml (~/.codex/config.toml)
    \\  cursor       ~/.cursor/mcp.json
    \\  vscode       ./.mcp.json (this workspace; the same file and entry
    \\               as Claude Code's)
    \\
    \\The assistant signs in through your browser on first use; no key is
    \\written to any file. The account needs API access: a 403
    \\`api_access_required` means ask support@getcadastre.com to enable it.
    \\
    },
    .{ .name = "docs", .text =
    \\Usage: cadastre docs [page] [--print]
    \\
    \\Opens the docs (<site>/docs, or <site>/docs/<page>, e.g. api, mcp,
    \\rights) in the browser. --print only prints the URL.
    \\
    },
    .{ .name = "version", .text =
    \\Usage: cadastre version [--json]
    \\
    },
};

pub fn print(app: *App, topic: ?[]const u8) void {
    const name = topic orelse {
        app.out.writeAll(overview) catch {};
        return;
    };
    for (topics) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            app.out.writeAll(t.text) catch {};
            return;
        }
    }
    _ = app.fail(.usage, "no help for \"{s}\". See `cadastre help`", .{name}) catch {};
}

test "every command has help" {
    const names = [_][]const u8{ "login", "logout", "whoami", "datasets", "measures", "metros", "metro", "compare", "screen", "rank", "mcp", "docs", "version" };
    for (names) |n| {
        for (topics) |t| {
            if (std.mem.eql(u8, t.name, n)) break;
        } else return error.MissingHelp;
    }
}
