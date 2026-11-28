# bash completion for wgtoggle
_wgtoggle() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "list status up down profile routes conflicts dns check health version diagnose help" -- "$cur"))
    return
  fi
  local IFS=$'\n'
  case ${COMP_WORDS[1]} in
    up|down|check) COMPREPLY=($(compgen -W "$(wgtoggle list --names 2>/dev/null)" -- "$cur")) ;;
    profile) [[ $COMP_CWORD -eq 2 ]] && COMPREPLY=($(compgen -W "$(wgtoggle list --profiles 2>/dev/null)" -- "$cur")) ;;
    status|routes) COMPREPLY=($(compgen -W "--json" -- "$cur")) ;;
  esac
}
complete -F _wgtoggle wgtoggle
