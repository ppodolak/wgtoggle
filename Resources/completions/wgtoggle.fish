set -l cmds list status up down profile routes conflicts dns version diagnose help
complete -c wgtoggle -f
complete -c wgtoggle -n "not __fish_seen_subcommand_from $cmds" -a "$cmds"
complete -c wgtoggle -n "__fish_seen_subcommand_from up down" -a "(wgtoggle list --names 2>/dev/null)"
complete -c wgtoggle -n "__fish_seen_subcommand_from profile" -a "(wgtoggle list --profiles 2>/dev/null)"
complete -c wgtoggle -n "__fish_seen_subcommand_from status routes" -l json
