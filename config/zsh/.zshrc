export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

case "$(uname -s)" in
  Darwin)
    DOTFILES_PLATFORM="macos"
    ;;
  Linux)
    DOTFILES_PLATFORM="linux"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    DOTFILES_PLATFORM="windows"
    ;;
  *)
    DOTFILES_PLATFORM="other"
    ;;
esac

_dotfiles_prepend_path() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

_dotfiles_source_if_exists() {
  [ -f "$1" ] && source "$1"
}

if [[ -o interactive && -t 0 && -t 1 ]] && command -v direnv >/dev/null 2>&1; then
  emulate zsh -c "$(direnv export zsh)"
fi

if [[ -r "$XDG_CACHE_HOME/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "$XDG_CACHE_HOME/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
DISABLE_AUTO_UPDATE="true"
HYPHEN_INSENSITIVE="true"

plugins=(
  git
  sudo
  extract
  colored-man-pages
  command-not-found
  zsh-autosuggestions
  zsh-syntax-highlighting
)

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' rehash true

if [ -n "${LS_COLORS:-}" ]; then
  zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
fi

if [ -s "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
fi

HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt EXTENDED_HISTORY
setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS
setopt PUSHD_SILENT
setopt COMPLETE_IN_WORD
setopt ALWAYS_TO_END
setopt INTERACTIVE_COMMENTS
setopt NO_BEEP

bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^H' backward-kill-word
bindkey '^[[3;5~' kill-word

ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=30

export LESS='-R'
export BAT_THEME='TwoDark'
export FZF_DEFAULT_OPTS='--height=40% --layout=reverse --border'
export CONDA_CHANGEPS1=false

if command -v nvim >/dev/null 2>&1; then
  export EDITOR='nvim'
  export VISUAL='nvim'
else
  export EDITOR='vim'
  export VISUAL='vim'
fi

_dotfiles_prepend_path "$HOME/.local/bin"
_dotfiles_prepend_path "$HOME/.cargo/bin"
_dotfiles_prepend_path "$HOME/go/bin"

case "$DOTFILES_PLATFORM" in
  macos)
    _dotfiles_prepend_path "/opt/homebrew/bin"
    _dotfiles_prepend_path "/opt/homebrew/sbin"
    _dotfiles_prepend_path "/usr/local/bin"
    _dotfiles_prepend_path "/usr/local/sbin"
    _dotfiles_prepend_path "$HOME/Library/pnpm"
    ;;
  linux)
    _dotfiles_prepend_path "/usr/local/bin"
    _dotfiles_prepend_path "/usr/local/sbin"
    _dotfiles_prepend_path "$HOME/.local/share/pnpm"
    ;;
  windows)
    _dotfiles_prepend_path "/ucrt64/bin"
    _dotfiles_prepend_path "/mingw64/bin"
    _dotfiles_prepend_path "/usr/local/bin"
    _dotfiles_prepend_path "/usr/bin"
    if [ -n "${APPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
      _dotfiles_prepend_path "$(cygpath -u "$APPDATA")/npm"
    fi
    ;;
esac

if command -v fzf >/dev/null 2>&1; then
  eval "$(fzf --zsh 2>/dev/null)" || true
fi

if [ -f /opt/homebrew/opt/fzf/shell/completion.zsh ]; then
  source /opt/homebrew/opt/fzf/shell/completion.zsh
fi
if [ -f /opt/homebrew/opt/fzf/shell/key-bindings.zsh ]; then
  source /opt/homebrew/opt/fzf/shell/key-bindings.zsh
fi
if [ -f /usr/local/opt/fzf/shell/completion.zsh ]; then
  source /usr/local/opt/fzf/shell/completion.zsh
fi
if [ -f /usr/local/opt/fzf/shell/key-bindings.zsh ]; then
  source /usr/local/opt/fzf/shell/key-bindings.zsh
fi

alias proxyon='export http_proxy="http://127.0.0.1:10808"; export https_proxy="http://127.0.0.1:10808"; export all_proxy="socks5://127.0.0.1:10808"; echo "proxy enabled on :10808"'
alias proxyoff='unset http_proxy; unset https_proxy; unset all_proxy; echo "proxy disabled"'
alias checkip='curl -L ip.gs'

if command -v eza >/dev/null 2>&1; then
  alias ls='eza --color=auto'
  alias ll='eza -lah --group-directories-first --git'
  alias la='eza -a'
  alias lt='eza --tree --level=2 --group-directories-first'
else
  if [ "$DOTFILES_PLATFORM" = 'macos' ]; then
    alias ls='ls -G'
  else
    alias ls='ls --color=auto'
  fi
  alias ll='ls -lah'
  alias la='ls -A'
fi

alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias c='clear'
alias h='history'
alias j='jobs -l'

alias gs='git status -sb'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit --amend'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gb='git branch'
alias gba='git branch -a'
alias gl='git pull'
alias gp='git push'
alias gd='git diff'
alias gds='git diff --staged'
alias glog='git log --oneline --graph --decorate --all'

alias py='python3'
alias v='nvim'
alias reload='exec zsh'

if command -v bat >/dev/null 2>&1; then
  alias cat='bat --style=plain --paging=never'
fi

mkcd() {
  mkdir -p "$1" && cd "$1"
}

fkill() {
  local pid
  pid=$(ps -ef | sed 1d | fzf -m | awk '{print $2}')
  if [ -n "$pid" ]; then
    echo "$pid" | xargs kill -9
  fi
}

if [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
  _dotfiles_source_if_exists "$NVM_DIR/bash_completion"
fi

if command -v pyenv >/dev/null 2>&1; then
  export PYENV_ROOT="$HOME/.pyenv"
  _dotfiles_prepend_path "$PYENV_ROOT/bin"
  eval "$(pyenv init - zsh)"
fi

if command -v nodenv >/dev/null 2>&1; then
  eval "$(nodenv init - zsh)"
fi

if [[ -o interactive && -t 0 && -t 1 ]] && command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook zsh)"
fi

if command -v conda >/dev/null 2>&1; then
  eval "$(conda shell.zsh hook 2>/dev/null)"
fi

if [ "$DOTFILES_PLATFORM" = 'windows' ]; then
  if command -v file.exe >/dev/null 2>&1; then
    export YAZI_FILE_ONE="$(command -v file.exe)"
  elif [ -x /usr/bin/file.exe ]; then
    export YAZI_FILE_ONE='/usr/bin/file.exe'
  fi
fi

[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
