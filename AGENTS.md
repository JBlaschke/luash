# Code style

Use these preferences for code you write or edit, across languages. They are
intentional and may differ from a language's conventional style. Aim for
compact, readable code with clear visual structure. Apply judgment, not
mechanical rules.

**Most examples use Julia and Python, but these style rules apply to all
languages.** Adapt the layout to each language's syntax; do not limit these
preferences to Julia or Python files.

## Indentation and line length

- Use **4 spaces** per indentation level, not tabs, except where the language
  or required tooling mandates otherwise.
- YAML uses **2 spaces** per level. The spec leaves the width open, but
  Kubernetes, Helm, kind and nu's `to yaml` all write 2, and the YAML here
  is compared with and copied from their output. Keep each file's
  sequence style (`- ` at its key's indentation, or indented under it),
  and do not pad after `key:` to align values. A block scalar (`|`, `>`)
  is data: it may shift only as a whole block, and shell code in one
  follows the Bash rules.
- Aim for **about 80 characters per line**, including indentation. This is a
  soft target. A modest overrun is preferable to awkward wrapping, cryptic
  names, or unnecessary intermediate variables.
- URLs, hash digests, and exact-output strings are explicit exceptions to the
  80-character target. Keep them intact when splitting or rewriting them would
  make verification harder or risk changing their bytes.
- Keep short calls and function signatures on one line when they read
  naturally.

## One action per line; align related code

- Put independent statements or actions on separate lines. Do not combine
  mutations just because they update related state. Avoid semicolon-separated
  statements and other tricks that squeeze sequential actions onto one line.
- This does not prohibit multiple arguments on a line, ordinary nested
  expressions, or semicolons required by syntax, such as Julia keyword argument
  separators or C-style loop headers.
- Vertically align related assignments, field declarations, type annotations,
  and named arguments when a small local group benefits from it.
- Keep alignment local and restrained. Do not add excessive padding, align
  unrelated code, or split compact argument groups solely to align their `=`,
  except for the declaration layout with default values described below.

For example:

```julia
used         += 1
kept         += 1
buffer[used]  = value

push!(result.x, x)
push!(result.y, y)
```

## Calls, constructors, and argument grouping

- When a call needs wrapping, keep the function name and opening `(` together,
  then start the arguments on the next line.
- Indent argument lines **4 spaces beyond the containing statement's base
  indentation**. Never align them under the opening parenthesis or first
  argument.
- Put the closing `)` on its own line, aligned with the containing statement's
  base indentation. Keep any required punctuation with it.
- Prefer **several short, related arguments on each line**. This applies to
  positional arguments, keyword/named arguments, and declaration parameters,
  with an exception for declarations that specify default values (see below).
- Break near the width target, or earlier when it keeps a meaningful group
  together. Do not fill every line to capacity at the expense of grouping.
- Use one argument per line when arguments are long or complex, or when a
  vertical list materially improves readability. It is not the default simply
  because a call or signature spans multiple lines.
- Apply the same rules to constructor calls and object initialization. Group
  short related fields where syntax allows; give complex fields their own
  lines.

```julia
next_edges, splits, merges = refine_edges(
    edges, counts;
    max_cells, min_cells, min_width = width,
    split_factor, merge_factor, merge_tolerance
)

grid = learn_grid(
    source;
    initial_cells = 32, max_cells = 256, min_cells = 6,
    split_factor = 1.5, merge_factor = 0.5, merge_tolerance = 0.25
)
```

- When the argument consists of a single list, dict, or another function call,
  then it's preferred to group that token with the opening/closing parenthesis.
  E.g:

```julia
my_function([
    "long", "list", "of", "inputs"
])
my_outer_function(my_inner_function(
    param_a, param_b, [x, y, z]
))
```

## Wrapped function declarations and definitions

Declarations use extra indentation to distinguish parameters from the body.
Relative to the indentation of the declaration itself:

- Parameter lines: **12 spaces** (three indentation levels).
- Closing `)`: **8 spaces** (two indentation levels).
- Function body: **4 spaces** (one indentation level).

Keep the opening `(` on the declaration line. Keep necessary syntax such as a
colon, return annotation, or opening brace with the closing `)` where
appropriate. This applies to functions, methods, and constructor definitions.
Calls still use the ordinary call layout above. All offsets are relative,
including in nested code.

```julia
function refine_edges(
            edges, counts; max_cells, min_cells, min_width,
            split_factor, merge_factor, merge_tolerance
        )
    target = sum(counts) / max_cells
    widths = diff(edges)
    # ...
end
```

For declarations that specify default values, **one parameter per line is also
fine**, even when the parameters are short. Align related defaults when
helpful. This is an option, not a requirement: compact groups remain fine, and
required parameters can stay grouped while parameters with defaults get their
own lines.

For example, in Python:

```python
def build_report(
            records, columns, filters,
            title          = "Summary",
            include_totals = True,
            precision      = 2
        ):
    rows = select_rows(records, columns, filters)
    # ...
```

## Rust refinements

- Wrapped Rust function and method declarations follow the repository's stable
  rustfmt configuration. Use its normal parameter indentation and closing
  delimiter layout instead of the 12/8-space declaration layout above. Do not
  add `#[rustfmt::skip]` solely to enforce that declaration layout.
- Stable rustfmt is the authority for Rust layout, and CI runs
  `cargo fmt --check`. In code that rustfmt formats, wrapped call arguments go
  one per line, and assignments, fields, and named arguments are not column
  aligned: rustfmt has no option for either. Reserve `#[rustfmt::skip]` for a
  small group whose semantic grouping materially improves readability, and say
  in a comment what it keeps together.
- rustfmt leaves some code verbatim: a statement that holds a string literal
  too long for its line, and a macro call it cannot parse as expressions, such
  as `matches!` with a guard or `json!`. Lay that code out by hand in the style
  above, with the long literal alone on its line, short related arguments
  grouped, and a nested call kept with its parentheses
  (`assert!(matches!(` ... `));`).

## Nushell refinements

- Nushell commands take no argument parentheses, so a wrapped command is
  enclosed whole: `(cmd sub` on the first line, argument lines at +4, and `)`
  alone at the statement's base indentation. Keep each flag on the same line
  as its value.
- A command continues onto another line only inside a delimiter opened on its
  first line: that `( )` wrapper, or a hugged `[` (`...[` for an external),
  `{` or `{|x|`. Arguments after a hugged delimiter go on its closing line
  (`] --flag`, `} $arg`). Outside strings, never end a line with `\`. A line
  left outside the delimiters is a separate statement: a bare word at its
  start runs as a command, and a lone flag or value is discarded or becomes
  the block's value.
- Inside `( )` a newline is whitespace, so two commands there merge into one
  call. Put one command or pipeline in each pair of parentheses. When one
  value needs several statements, write them on the lines before it or in a
  `do { }` block, not joined by `;`. A `do { }` block cannot use an outer
  `mut`, and its `cd` and `$env` changes end with it.
- Keep `} else {`, `} catch {`, `} finally {`, `] {` and `]: in -> out {` on
  one line. An `else`, `catch` or `finally` on its own line fails at runtime,
  after the `if` or `try` before it has run.
- A pipeline that fits stays on one line. Otherwise put one stage per line,
  each starting with `|` at the indentation of the pipeline's first line,
  with no blank lines between stages: a blank line ends the pipeline.
  Comment lines are fine. To assign a wrapped pipeline, end the `let x =`
  line with `(`, put the head and stages at +4, and `)` alone at base. To
  wrap an expression at an operator (`and`, `+`), put it inside `( )` and
  start each continuation line with the operator.
- Wrapped signatures put parameters at +4 and `] {` at the `def` line's
  indentation, instead of the 12/8 layout; most nushell code, including its
  standard library, uses this layout.
- A comment block directly above a `def`, with no blank line between, becomes
  its `--help` description, including a shebang line. Write a plain sentence
  there, and put a blank line after the shebang and after a file banner when
  a comment block or `def` follows.
- A trailing comment on a parameter's line is its `--help` text. Give each
  documented parameter its own line, since the comment documents only the
  last parameter on its line. Put no own-line comments inside `[ ]`: each is
  appended to the previous parameter's help. Keep each parameter's comment on
  one line, even past the width target; shorten it rather than wrap it.
- Alignment padding is fine in signatures (types, defaults and help
  comments), in `let` and `mut`, after a record key's colon, and before `=>`
  in match arms. At call sites align only `--flag value` pairs; never pad
  `--flag=value`.
- Multi-line string bodies are data: re-indenting code must not change their
  bytes. A `str dedent` string may shift only as a whole block, with its
  closing quote at the content's left edge. Never re-indent the content
  itself, such as embedded TOML.
- Shell code in a string follows the bash rules below, and POSIX for
  `sh -c`. Write it in `'...'` or `r#'...'#` and pass values as arguments
  (`^sh -c $script sh $a`): in `$'...'` every `(` starts an interpolation.
- `nu-check` reports only parse errors, and most of these mistakes parse.
  After a layout change, read each continuation line by eye. If the top
  level holds only `def`, `const` and `use` (`source` runs anything else),
  also diff `nu -n -c 'source script.nu; help name'` before and after for
  each changed `def`: help shows its signature and description, not its body.

```nu
# Build every image directory under images/ with podman.
def build-all [
    --tag:    string = "latest"  # Tag to apply to each image
    --format: string = "docker"  # Manifest format for podman build
] {
    let dirs = ls images | where type == dir | get name
    for dir in $dirs {
        (^podman build
            --format $format --tag $"($dir | path basename):($tag)"
            --file ($dir | path join Containerfile)
            $dir
        )
    }
}
```

## Bash refinements

These apply to `.sh` files, Containerfile `RUN` instructions, and shell code
in strings. Code that `sh` runs is a `RUN` with no `SHELL ["bash", "-c"]` in
effect, a file written to `/etc/profile.d` (whatever its shebang), and an
`sh -c` string. It must stay POSIX, with no bash-isms such as arrays,
`[[ ]]`, `(( ))`, `+=`, `==`, `&>` or `source`, and no `set -o pipefail`,
which the dash in Ubuntu 24.04, this repo's base, rejects. A `SHELL` holds
for the rest of its stage and in stages built `FROM` that stage. A stage
`FROM` another image gets that image's `SHELL` (the builds here use
`--format docker`, which keeps it), and the Containerfile does not show it.
So a stage on an image with bash declares `SHELL ["bash", "-c"]` before its
first `RUN`, unless it is `FROM` a stage of the same file that has it in
effect; on an image without bash, such as Alpine, its `RUN`s stay POSIX.

- Start a bash script or `bash -c` string with `set -euo pipefail`, a
  `RUN <<EOR` body with `set -xeuo pipefail` (comments may come before
  it), and an `sh -c` string or a script that `sh` runs as its own process
  with `set -eu`. A classic `RUN` and a sourced file set none (see below).
  The `-x` trace shows where a build stopped; put lines that read or use a
  secret, such as a file in `/run/secrets`, between `set +x` and `set -x`.
  README commands are typed into an interactive shell and set no options
  there, but an `sh -c` string in one follows this rule; a script and its
  README copy change together.
- A file that another shell sources, such as one in `/etc/profile.d` or a
  library, leaves the caller's options as it found them: options it sets
  stay on in the caller, and a login shell with `-e` exits at its first
  failed command. It must still work under a caller's `-eu`, and a bash
  library under `-euo pipefail` too. Put no options in `SHELL`, nor on the
  command line of a login or interactive bash (`bash -eu -l`): the image
  passes `SHELL` to every image built `FROM` it, and command-line options
  are already on while the startup files run. Never export `SHELLOPTS`: a
  child bash, such as a third-party installer, then inherits `-e`, `-u` and
  `pipefail`.
- Never put whitespace around `=` in an assignment. Align only trailing
  comments, `case` arms, `(( ))` expressions and the padding between array
  elements. Under `set -e`, bash 5 stops at a `(( ))` statement whose value
  is 0 (`(( n++ ))` when `n` is 0), so count with `n=$(( n + 1 ))`.
- The 12/8 layout does not apply, since functions have no parameter list.
  Name positional parameters at the top of the body, one `local` per line
  (`local tag="${2:-latest}"`).
- Allowed semicolons: `; then` and `; do` at the end of a condition or loop
  header, `;;` in `case`, and the `;` before `}` in a one-line function or
  `{ }` group. A single guard (`cd "$dir" || exit 1`) stays on the line it
  guards. Split one-line `if ...; then ...; fi` blocks.
- `set -e` ignores a failure of `a` in `a && b`, and of any command in a
  function called as a condition (`if f`, `! f`, `f || g`); bash also turns
  it off inside `$( )`. Where `set -e` holds, write a sequence as separate
  lines; elsewhere, keep the `&&`. Write a condition as an `if` block: as
  the last command, a false `[ ... ] && b` fails the `RUN`, function or
  script.
- Declare and assign a command substitution separately (`local tag`, then
  `tag="$(...)"`): `local tag="$(...)"` hides the failure.
- Under `-u`, expand a variable that may be unset as `${VAR:-}` (`${1:-}`
  for an optional argument, `${VAR-word}` when an empty value must not get
  the default), test whether it is set with `[ -n "${VAR+x}" ]` (bash 3.2
  has no `[[ -v ]]`), and require one with `: "${VAR:?message}"`. A bare
  `local x` read before its first assignment may be unset or keep an outer
  value, so write `local x=""` there.
- Third-party code that reads unset variables runs between `set +u` and
  `set -u` lines with a comment naming it, and is never sourced in a
  helper function, where its `declare` and `local` variables are lost.
  This covers only what runs between the lines, so a function the code
  defines (Lmod's `module`) is called between them too, also in a script
  that gets it from a sourced file. The lines leave `-e` and `pipefail`
  on: around code that may fail or holds pipelines, use `set +euo pipefail`
  and `set -euo pipefail`. In a sourced file, where the caller's options
  are unknown, save `$-` in a variable named after the file, `set +eu` (a
  `.` returns the status of the file's last command, which stops a `-e`
  caller), restore each option with its own `case`, which sets it or, in a
  `*)` arm, clears it, then `unset` the variable. Drop `-u` from a whole
  script (`set -eo pipefail`, `set -xeo pipefail` in a `RUN <<EOR` body,
  `set -e` in `sh` code) only when such code runs through most of it, with
  a comment above naming that code; never for the script's own variables.
- Under `pipefail`, a pipeline fails when a `grep` before its last stage
  matches nothing, and, depending on output size, when a reader that stops
  early (`head`, `grep -q`, `sed 1q`) kills the writer with SIGPIPE
  (status 141), with no message. Allow just the expected status:
  `{ grep pat || [ $? -eq 1 ]; }` where no match is fine (not in a check
  that a match is there), or `{ cmd || [ $? -eq 141 ]; } | head -n 1` when
  `cmd` is an external program and the last writer in the group.
  Otherwise read all the input (`grep pat >/dev/null` for `grep -q`) or
  capture the output first, as a `grep` that feeds an early reader needs.
  Never add `|| true` to a whole pipeline: it hides a failed writer too.
  `sh` code has no `pipefail`: there, save a writer's output to a file or
  variable first when its failure matters.
- Continuation lines go at +4, each flag with its value. Nothing follows the
  `\`, and no comment or blank line comes between continued lines: outside a
  classic `RUN`, each ends the command, and the remaining lines run as a
  separate command. The last line has no `\`: one there pulls the next line
  into the command.
- For commented or conditional arguments, build an array: `args=(` on the
  first line, grouped elements at +4, `)` alone at base indentation, then
  `cmd "${args[@]}"`. A wrapped substitution is `var="$(` ... `)"`.
- Wrapped pipelines and `&&`/`||` lists start each continuation line with the
  operator, after a `\` on the line before.
- Redirections for a loop or group stay on its closing line
  (`done < "$file"`, `} > "$out"`).
- A heredoc body is data: never re-indent it to match the code. Its
  terminator starts the line, and `<<-` strips only tabs, so do not use it.
  A `RUN <<EOR` body is shell code, though, and follows these rules inside.
- To shorten a URL, move a prefix into a variable; never split a word across
  lines with `\`.
- A classic `RUN`, on one line or joined with `\`, sets no options, so keep
  it to a plain `&&` chain: a pipe, loop, condition or possibly unset
  variable goes in a `RUN <<EOR` body. `RUN cat <<'EOF' > file` writes data
  and sets none either. The Dockerfile parser joins the `\` lines and drops
  full-line comments before the shell runs, and a trailing comment on a
  continued line hides the rest of the `RUN`. Join with `&&`, never `;`:
  without `set -e`, the shell goes on past a failure before a `;`. A
  `RUN <<EOR` body reaches the shell as written.
- Check changed shell code with shellcheck (`-s sh` for POSIX code) and a run
  under bash 5 (dash for POSIX code), with stubs on `PATH` for commands that
  install, download or change the system. Read continuation lines by eye:
  neither `bash -n` nor shellcheck reliably reports a continuation cut short
  by a comment or blank line. macOS `/bin/bash`, which a bare `bash` may
  resolve to, is 3.2, where an empty `"${args[@]}"` fails under `set -u`;
  `${args[@]+"${args[@]}"}` works in both, unless `IFS` is empty.

```bash
#!/usr/bin/env bash
set -euo pipefail

build_image() {
    local image="$1"
    local tag="${2:-latest}"
    local args=(
        --format docker --tag "$image:$tag"
        --layers  # reuse cached layers between builds
    )
    if [[ -n "${CACHE_FROM:-}" ]]; then
        args+=(--cache-from "$CACHE_FROM")
    fi
    podman build "${args[@]}" "$image"
}

set +u  # /opt/vendor/env.sh and its vendor_init read unset variables
# shellcheck source=/dev/null
. /opt/vendor/env.sh
vendor_init
set -u

podman images --format '{{.Repository}}:{{.Tag}}' \
    | { grep '^localhost/' || [ $? -eq 1 ]; } \
    | sort
```

## Apply with judgment

Preserve language syntax and program behavior. These examples illustrate
layout, not naming conventions, API design, or a requirement to rewrite code
into Julia idioms. Use the equivalent layout where a language has different
delimiters.

Apply the style to new and changed code without reformatting unrelated
sections. Do not run a formatter that silently replaces these choices with its
defaults. Respect mandatory tooling constraints; where formatting is
configurable, prefer these rules. Readability and useful grouping take
precedence over rigid column limits, excessive alignment, or blanket
one-argument-per-line formatting.

## Scope in this repository

Never restyle `vendor/**` (also reached through the `slinky-*` symlinks) or
`generated/**`; regenerate `generated/` instead (README.md, steps 1 and 2).
Files derived from upstream (those with a SchedMD SPDX header) keep the
upstream layout, so that their diff against upstream stays small. Where a
file or block uses another indentation width, edits match the enclosing
block, and each +4 above counts as one level of that width. Convert a
whole file only in a dedicated formatting commit.
