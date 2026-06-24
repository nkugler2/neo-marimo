# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for
anything exploitable.

- Preferred: open a private advisory via GitHub →
  [**Report a vulnerability**](https://github.com/nkugler2/neo-marimo/security/advisories/new)
  (the *Security* tab → *Advisories* → *Report a vulnerability*).
- If you can't use GitHub advisories, you can reach the maintainer at
  `nkugler2@asu.edu`.

Please include: what you observed, steps to reproduce, your Neovim and marimo
versions, your OS/terminal, and the impact you think it has. We'll acknowledge
receipt, work with you on a fix, and credit you in the release notes unless you
prefer to stay anonymous.

## Supported versions

neo-marimo is pre-1.0; the public API (the four extension registries in
`docs/architecture.md`) may still move. Security fixes are applied to the
latest tagged release and `master`. The rendering pipeline is fixture-tested
against the marimo **0.19** and **0.23** series (see
`lua/neo-marimo/health.lua`); other series may work but aren't covered.

## Trust model

neo-marimo runs **entirely on your machine**. It has no network service of its
own, sends nothing to any third party, and stores no credentials. The trust
boundary is therefore local, and rests on two things:

1. **The notebook file you open.** A marimo notebook *is* Python code. Running
   it executes that code with your user's privileges — exactly like running the
   `.py` yourself, or opening it in Jupyter or marimo's own browser editor.
2. **Other processes/users on the same machine** (see "Local kernel
   authentication" below).

> [!IMPORTANT]
> **Do not run untrusted notebooks.** Opening a notebook in the view only
> *parses* it (no execution). But starting the kernel — `<leader>ms`,
> `<leader>mo`, or running a cell — executes the notebook's Python. Treat a
> `.py` from an untrusted source the same way you'd treat any script you're
> about to run: read it first.

## Local kernel authentication (`--no-token`)

neo-marimo launches the marimo server with `--no-token`, which **disables
marimo's session authentication**. This is a deliberate tradeoff: it lets the
browser and Neovim share marimo's single EDIT-mode connection slot without a
token-handshake dance. The `Marimo-Server-Token` header the plugin sends is
marimo's *skew-protection* token (a version/CSRF guard), **not an
authentication secret** — it is published in the server's own HTML and any
local process can read it.

What this means:

- **By default the server binds to `127.0.0.1` (loopback only).** The kernel —
  including the `/api/kernel/run` endpoint, which executes arbitrary Python —
  is reachable by **any process or user on the same machine, with no
  authentication.**
- On a **single-user workstation**, this is a low-risk, local-only exposure
  (anything that can hit `127.0.0.1` can already run code as you).
- On a **shared or multi-user host**, this is effectively local code execution
  as your user for anyone else with access to the loopback interface. Be aware
  of it before running neo-marimo on such a host.

### Do not bind to a non-loopback address

Because authentication is off, setting `server.host` to a non-loopback address
(`0.0.0.0`, a LAN IP, etc.) publishes an **unauthenticated arbitrary-Python
execution endpoint to your whole network**. neo-marimo emits a warning when it
detects a non-loopback host, but it does not stop you. Don't do this unless the
interface is otherwise firewalled and you understand the consequence.

```lua
require("neo-marimo").setup({
  server = {
    host = "127.0.0.1", -- default; keep it loopback unless you really mean it
  },
})
```

If you need authenticated, exposable access, prefer marimo's own
`marimo edit` with a token (`--token` / `--token-password-file`) directly,
rather than driving it through neo-marimo's `--no-token` path.

## What neo-marimo does *not* do

- It does not embed any API keys, tokens, or passwords (the marimo token is
  fetched from the local server at runtime, never committed).
- It does not issue SQL or build database queries.
- It does not render output as executable markup — cell output is parsed and
  drawn as Neovim virtual text, not interpreted as HTML/JS.
- Its only Python imports are `marimo` and `websockets` (a declared marimo
  dependency); its only optional Lua dependencies are `image.nvim` and
  `snacks.nvim`, both loaded defensively with `pcall(require)`.

## Hardening notes for contributors

- The server is local and trusted *by design*, but treat cell **output** as
  untrusted input: it originates from notebook code. Renderers must not feed
  server-supplied strings into `vim.cmd`, `loadstring`, `os.execute`, shell
  invocations, or terminal escape sequences.
- Server-referenced virtual files (`<img src='./@file/…'>`) are fetched over
  loopback HTTP; the fetch path rejects `..` segments to avoid traversal
  outside marimo's `@file` namespace (`server.lua`, `fetch_virtual_file`).
- All HTTP/WS calls target `127.0.0.1` explicitly; keep them consistent with
  whatever `server.host` resolves to.
