#!/usr/bin/env bash
# tui-helpers.sh — Reusable interactive input primitives for hephaestus scripts
#
# Source this file; do not execute it directly.
#
# Functions:
#   ask            <prompt> <varname>          Single-line input (y/n, choices)
#   ask_multiline  <prompt> <varname>          Multi-line input, sentinel "." to end
#   ask_or_file    <prompt> <varname>          Multi-line input or @path shorthand

# Single-line prompt. Use for: y/n, 1/2/3 choices, short strings.
ask() {
  printf "  %s: " "$1"
  read -r "$2"
}

# Multi-line prompt. Use for: any input the user might paste or write across
# multiple lines (ideas, clarifications, feedback, corrections).
#
# Usage: ask_multiline "Your prompt text" VARNAME
#
# Rules:
#   - Shows the prompt, then waits for lines
#   - Ends when the user types a line containing only "."
#   - Also accepts "@/path/to/file" as the first line to load from a file
#   - Result is stored in VARNAME (no trailing newline)
ask_multiline() {
  local _prompt="$1"
  local _varname="$2"
  local _lines=""
  local _line

  echo "  ${_prompt}"
  echo "  (Paste or type. Enter a line with just '.' when done,"
  echo "   or type '@/path/to/file' to load from a file.)"
  echo ""

  while IFS= read -r _line; do
    # File shorthand: @path on its own line
    if [[ "$_line" == @* ]]; then
      local _fpath="${_line#@}"
      _fpath="${_fpath# }"   # strip optional leading space
      if [ -f "$_fpath" ]; then
        _lines="$(cat "$_fpath")"
        echo "  (loaded $(wc -l < "$_fpath") lines from $_fpath)"
        break
      else
        echo "  ✗ File not found: $_fpath — continuing with typed input" >&2
        continue
      fi
    fi

    # Sentinel
    [[ "$_line" == "." ]] && break

    _lines="${_lines}${_line}"$'\n'
  done

  # Strip trailing newline
  printf -v "$_varname" '%s' "${_lines%$'\n'}"
}

# ask_or_file: identical UX to ask_multiline.
# Alias kept for clarity at call sites where "file or type" is the intent.
ask_or_file() {
  ask_multiline "$1" "$2"
}
