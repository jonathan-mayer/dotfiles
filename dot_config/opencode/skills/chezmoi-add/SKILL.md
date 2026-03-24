---
name: chezmoi-add
description: Add bash aliases, functions, config files, scripts, or any managed item to this chezmoi dotfiles repository following its established patterns and conventions
---

# Adding Configs, Bash Aliases/functions to the Chezmoi Repository

## What I do

Guide the addition of new managed items to this chezmoi repository, including:

- Bash aliases and functions (sourced scripts)
- Application config files (static or templated)
- Run scripts (executed by chezmoi on apply)
- Template data and conditional ignores
- Package tracking entries

## Repository layout

Use stable anchors plus dynamic discovery, instead of relying on a fixed file list.

Stable anchors in this repo:

- `.chezmoi.toml.tmpl` for prompts and data model
- `.chezmoiignore` for conditional deployment
- `.chezmoidata/packages.yaml` for package tracking
- `scripts/` for sourced shell behavior
- `run_after_*.sh.tmpl` and `run_onchange_*.sh.tmpl` for apply hooks

Discover current files and categories dynamically:

```bash
# top-level source inventory
ls -1

# shell setup modules that get sourced by .bashrc
ls -1 scripts/executable_setup-*.bash*

# templated files currently in repo
rg --files -g "*.tmpl"

# managed app configs under ~/.config
ls -1 dot_config
```

The files will be rendered by chezmoi to the users home `~/`

## Chezmoi naming conventions

These prefixes in filenames control how chezmoi deploys them:

| Prefix          | Effect                                                         |
| --------------- | -------------------------------------------------------------- |
| `dot_`          | Rendered name starts with `.` (e.g. `dot_bashrc` -> `.bashrc`) |
| `private_`      | File created with `0600` permissions                           |
| `executable_`   | File created with executable bit set                           |
| `.tmpl` suffix  | Processed as Go template before writing                        |
| `run_after_`    | Script executed after every `chezmoi apply`                    |
| `run_onchange_` | Script executed only when its rendered content changes         |

Prefixes can be combined: `private_dot_netrc.tmpl` creates `~/.netrc` with `0600` permissions, templated.

## Template system

Templates use Go `text/template` syntax with data from `chezmoi.toml`:

- **Interpolation**: `{{ .name | quote }}`, `{{ .proxy }}`
- **Conditionals**: `{{- if .proxy }}...{{- end }}`
- **Range**: `{{- range .git.machines }}...{{- end }}`
- **OS detection**: `{{- if eq .chezmoi.osRelease.id "arch" }}`
- **Key checks**: `{{- if and (hasKey . "secrets") (hasKey .secrets "ai") }}`
- **Builtins**: `{{ .chezmoi.homeDir }}`, `{{ .chezmoi.osRelease.id }}`

### Discover template data dynamically

Do not hardcode an exhaustive list of available keys in this skill. Keys can change.

When you need to know what data is available, inspect the source of truth:

- `.chezmoi.toml.tmpl` (prompts and `[data]` output structure)
- Existing `*.tmpl` files (real usage patterns)
- `.chezmoiignore` (conditional keys currently in use)

Quick checks:

```bash
# find all .<key> references used in templates
rg -n "\{\{[^}]*\.[a-zA-Z0-9_\.]+" . --glob "*.tmpl"

# inspect generated data structure definitions
rg -n "^\[data|^\[\[data" .chezmoi.toml.tmpl
```

## How to add each type of item

### 1. Bash alias or function

All files matching `~/scripts/setup-*.bash` when rendered will be sourced by the `~/.bashrc`.

**If it fits an existing category**, add it to the relevant file in `scripts/`:

- `scripts/executable_setup-misc-aliases.bash.tmpl` - General aliases, git helpers, dev-\* commands
- `scripts/executable_setup-disk-aliases.bash` - Disk/mount aliases
- `scripts/executable_setup-auto-clear-aliases.bash` - Auto-clearing aliases
- `scripts/executable_setup-configure-bash.bash` - Shell options and env vars
- `scripts/executable_setup-configure-go.bash.tmpl` - Go environment
- `scripts/executable_setup-proxy.bash.tmpl` - Proxy configuration
- `scripts/executable_setup-bash-prompt.bash.tmpl` - PS1 prompt

**If it's a new category**, create a new file:

```text
scripts/executable_setup-<topic>.bash       # Static
scripts/executable_setup-<topic>.bash.tmpl  # If it needs template data
```

The file will be automatically sourced by `.bashrc` via the glob:

```bash
for file in ~/scripts/setup-*.bash; do . "$file"; done
```

No changes to `.bashrc` are needed. The `setup-` prefix and `.bash` extension are required.

**Pattern for functions with tab completion** (follow existing style):

```bash
myfunc() {
  # function body
}
_myfunc() {
  # completion logic
  COMPREPLY=( $(compgen -W "option1 option2" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _myfunc myfunc
```

### 2. Static config file

Place it in the chezmoi source using `dot_` naming to mirror the target path:

| Target                     | Source path                         |
| -------------------------- | ----------------------------------- |
| `~/.somerc`                | `dot_somerc`                        |
| `~/.config/app/config.yml` | `dot_config/app/config.yml`         |
| `~/.config/app/secret.yml` | `dot_config/app/private_secret.yml` |

### 3. Templated config file

Same as static but add `.tmpl` suffix. Use template data for values that vary per machine:

```text
dot_config/app/config.yml.tmpl
```

Example content:

```yaml
server: { { .proxy | default "direct" } }
user: { { .name } }
```

If the file contains credentials, add the `private_` prefix.

### 4. Conditional file (only deployed when relevant)

Add an ignore rule to `.chezmoiignore`:

```gotemplate
{{- if <condition> }}
<target-path-relative-to-home>
{{- end }}
```

Examples from this repo:

```gotemplate
{{- if .remote }}
.config/PrusaSlicer
{{- end }}
{{- if eq .secrets.ai "unset" }}
.continue/config.yaml
{{- end }}
```

Note: paths in `.chezmoiignore` use the **target** path (e.g. `.config/app/file`), not the source path.

### 5. New template data variable

1. Add a prompt to `.chezmoi.toml.tmpl`:

   ```gotemplate
   {{- $myvar := promptStringOnce . "myvar" "Description of variable" -}}
   ```

   Available prompt functions: `promptStringOnce`, `promptBoolOnce`, `promptInt`

2. Write it into the appropriate `[data]` section:

   ```toml
   myvar = {{ $myvar | quote }}
   ```

3. Use in templates as `{{ .myvar }}`

For existing data that needs preserving on re-init, use the `hasKey` guard pattern:

```gotemplate
{{- $myvar := "default" -}}
{{- if hasKey . "myvar" -}}
  {{- $myvar = .myvar -}}
{{- end -}}
```

### 6. System config file (in /etc/)

Place the file under `dot_chezmoi_etc/` mirroring the `/etc/` structure:

```text
dot_chezmoi_etc/systemd/system/myservice.conf.tmpl
```

The `run_after_chezmoi_etc.sh.tmpl` script automatically symlinks everything from `~/.chezmoi_etc/` into `/etc/` with sudo.

### 7. Run script

Create at the repo root:

- `run_after_<name>.sh.tmpl` - runs after every `chezmoi apply`
- `run_onchange_<name>.sh.tmpl` - runs only when rendered content changes

Always start with a shebang and `set -eu`:

```bash
#! /bin/bash
set -eu
# script body
```

### 8. Track a package

Add to `.chezmoidata/packages.yaml` under the `packages:` key:

```yaml
mypackage:
  type: "cli" # or "gui"
  sources:
    brew:
      name: "mypackage"
    pacman:
      name: "mypackage"
```

## When to use templates

Use `.tmpl` when the file needs:

- User-specific values (name, email, paths)
- Proxy-aware configuration
- OS-specific blocks (`{{- if eq .chezmoi.osRelease.id "arch" }}`)
- Conditional sections based on features (`.go_bins`, `.remote`, etc.)
- Secrets or tokens from `.secrets.*`

Use static (no `.tmpl`) when the file is identical across all machines.

## Proxy-aware pattern

Nearly every tool config conditionally includes proxy settings:

```gotemplate
{{- if .proxy }}
proxy = {{ .proxy | quote }}
{{- end }}
```

Apply this pattern when adding configs for network-aware tools.

## Verification

After making changes, verify with:

```bash
chezmoi diff # Preview what would change
```

## When to use me

Use this skill when you need to:

- Add a new bash alias, function, or shell script to the dotfiles
- Add or modify an application config file managed by chezmoi
- Add a new templated config that varies per machine
- Add a run script that executes during chezmoi apply
- Add new template data variables to the chezmoi config
- Track a new package in the package registry
- Understand the conventions and patterns used in this repository
