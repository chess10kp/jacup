"""Shell completion emitters for jacup and the jac it installs."""

def bashCompletions() -> str {
    return """# bash completion for jacup and the jac it installs
# install: add to your ~/.bashrc:
#   export PATH="$(jacup bin):$PATH"
#   source <(jacup completions bash)
_jacup_versions() {
  jacup list 2>/dev/null | awk '{print $1}'
}
_jacup() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cmd="${COMP_WORDS[1]}"
  if [ "$COMP_CWORD" -eq 1 ]; then
    local cmds="install uninstall update list aliases available use switch alias unalias pin unpin current path bin exec doctor completions help"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
  fi
  case "$prev" in
    completions)
      COMPREPLY=( $(compgen -W "bash zsh" -- "$cur") )
      return 0
      ;;
    --index-url)
      COMPREPLY=( $(compgen -f -- "$cur") )
      return 0
      ;;
  esac
  case "$cmd" in
    install)
      COMPREPLY=( $(compgen -W "latest" -- "$cur") )
      ;;
    uninstall|use|switch|pin)
      COMPREPLY=( $(compgen -W "$(_jacup_versions)" -- "$cur") )
      ;;
  esac
  return 0
}
complete -F _jacup jacup

_jac() {
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -eq 1 ]; then
    local cmds="run build test check fmt fix clean code config create db explain install lsp mcp model remove retheme scale setup tool update x"
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
  else
    COMPREPLY=( $(compgen -f -- "$cur") )
  fi
  return 0
}
complete -F _jac jac
""";
}

def zshCompletions() -> str {
    return """#compdef jacup jac
# zsh completion for jacup and the jac it installs
# install: add to your ~/.zshrc:
#   export PATH="$(jacup bin):$PATH"
#   source <(jacup completions zsh)
_jacup_versions() {
  local -a vers
  vers=(${(f)"$(jacup list 2>/dev/null)"})
  vers=(${vers%% *})
  _describe -t versions 'installed version' vers
}
_jacup() {
  local curcontext="$curcontext" state line
  typeset -A opt_args
  _arguments -C \\
    '1:command:->cmds' \\
    '*::arg:->args'
  case $state in
    cmds)
      local -a cmds
      cmds=(install uninstall update list aliases available use switch alias unalias pin unpin current path bin exec doctor completions help)
      _describe -t jacup-commands 'jacup command' cmds
      ;;
    args)
      case $words[1] in
        completions)
          _values 'shell' bash zsh
          ;;
        install)
          _values 'version' latest
          ;;
        uninstall|use|switch|pin)
          _jacup_versions
          ;;
        *)
          _default
          ;;
      esac
      ;;
  esac
}
_jac() {
  local curcontext="$curcontext" state line
  _arguments -C \\
    '1:command:->cmds' \\
    '*::arg:->args'
  case $state in
    cmds)
      local -a cmds
      cmds=(run build test check fmt fix clean code config create db explain install lsp mcp model remove retheme scale setup tool update x)
      _describe -t jac-commands 'jac command' cmds
      ;;
    args)
      _default
      ;;
  esac
}
compdef _jacup jacup
compdef _jac jac
""";
}
