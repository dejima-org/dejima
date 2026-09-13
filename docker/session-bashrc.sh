# Interactive shell configuration for the sandbox user.
#
# Loaded from /etc/bash.bashrc, so it applies to every interactive bash, and
# again from the sandbox user's ~/.bashrc, so it wins over the Debian skeleton
# rc file that would otherwise reset PS1 and the history limits after us.
# Sourcing it twice is harmless: everything below is an assignment or an
# idempotent binding.
#
# Not a shell framework fetched at build time. This image is a security
# boundary, and a prompt is not worth an unpinned third party in the build - so
# what a framework would have configured is written out here instead, where it
# can be read.

case $- in *i*) ;; *) return 0 ;; esac

# Debian's /etc/profile rewrites PATH from scratch for login shells: it drops
# the global Node tool directory the image put in the environment, and it leaves
# out the sbin directories, where the network tools a session is expected to use
# (ip, nft, dnsmasq) all live. Put them back, without duplicating an
# entry when this file is sourced twice.
# Appended, for the reason the Dockerfile gives: the harness wrapper in
# /usr/local/bin has to keep shadowing the npm-installed binary it wraps.
case ":$PATH:" in
  *":/opt/node-tools/bin:"*) ;;
  *) PATH="$PATH:/opt/node-tools/bin" ;;
esac
for __dir in /usr/local/sbin /usr/sbin /sbin; do
  case ":$PATH:" in
    *":$__dir:"*) ;;
    *) PATH="$PATH:$__dir" ;;
  esac
done
unset __dir

# History on the volume docker-compose.yml mounts, so tomorrow's session sees
# what was typed today. If the mount is missing or not writable by this user,
# fall back to the home directory rather than making every prompt fail to save.
if [ -w /var/opt/shell-history ]; then
  HISTFILE=/var/opt/shell-history/.bash_history
else
  HISTFILE="$HOME/.bash_history"
fi
HISTSIZE=50000
HISTFILESIZE=500000
HISTCONTROL=ignoreboth
HISTTIMEFORMAT='%F %T '
shopt -s histappend cmdhist checkwinsize

# Append each command to $HISTFILE as it is entered. Without this, bash holds
# the whole session in memory and writes on a clean exit only - and a sandbox
# session is killed far more often than it exits.
PROMPT_COMMAND='history -a'

if ! declare -F _completion_loader >/dev/null 2>&1; then
  [ -r /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
fi

# Git state in the prompt comes from git-sh-prompt, which ships inside the git
# package itself, so it is present whenever git is.
if ! declare -F __git_ps1 >/dev/null 2>&1 && [ -r /usr/lib/git-core/git-sh-prompt ]; then
  . /usr/lib/git-core/git-sh-prompt
fi
GIT_PS1_SHOWDIRTYSTATE=1
GIT_PS1_SHOWSTASHSTATE=1
GIT_PS1_SHOWUNTRACKEDFILES=1
GIT_PS1_SHOWUPSTREAM=auto
if declare -F __git_ps1 >/dev/null 2>&1; then
  PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0;33m\]$(__git_ps1 " (%s)")\[\e[0m\]\$ '
else
  PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi

# Fuzzy search over history and over paths, written here rather than sourced
# from whatever path the fzf package happens to keep its example bindings in -
# that path has moved between releases, and a key binding that silently stops
# existing after a distribution upgrade is worse than twenty lines of rc file.
if command -v fzf >/dev/null 2>&1; then
  export FZF_DEFAULT_OPTS='--height=40% --layout=reverse --border --info=inline'

  # Ctrl-R: search the history, most recent first, duplicates dropped. The sed
  # removes the entry number and the HISTTIMEFORMAT stamp that the history
  # builtin prints ahead of each command.
  __fzf_history_widget() {
    local picked
    picked=$(history |
      sed -E 's/^ *[0-9]+ +([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} )?//' |
      tac |
      awk '!seen[$0]++' |
      fzf --prompt='history> ' --query="$READLINE_LINE") || return 0
    READLINE_LINE=$picked
    READLINE_POINT=${#READLINE_LINE}
  }

  # Ctrl-T: insert one or more paths from below the current directory at the
  # cursor. fd rather than find, so a checkout's ignored build output does not
  # bury the file being looked for.
  __fzf_path_widget() {
    local picked
    picked=$(fd --hidden --exclude .git --strip-cwd-prefix 2>/dev/null |
      fzf --prompt='path> ' --multi |
      tr '\n' ' ') || return 0
    picked=${picked% }
    [ -n "$picked" ] || return 0
    READLINE_LINE=${READLINE_LINE:0:READLINE_POINT}$picked${READLINE_LINE:READLINE_POINT}
    READLINE_POINT=$((READLINE_POINT + ${#picked}))
  }

  bind -x '"\C-r": __fzf_history_widget'
  bind -x '"\C-t": __fzf_path_widget'
fi
