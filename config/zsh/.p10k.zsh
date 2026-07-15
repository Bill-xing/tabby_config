# Lean two-line prompt with strong Git visibility and minimal noise.
source "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/config/p10k-lean.zsh"

typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
  dir
  vcs
  newline
  prompt_char
)

typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
  status
  command_execution_time
  background_jobs
  direnv
  virtualenv
  anaconda
  pyenv
  nodenv
  nvm
  kubecontext
  aws
  context
  newline
)

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always
typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
typeset -g POWERLEVEL9K_STATUS_OK=false
typeset -g POWERLEVEL9K_CONTEXT_DEFAULT_CONTENT_EXPANSION=''
typeset -g POWERLEVEL9K_CONTEXT_DEFAULT_VISUAL_IDENTIFIER_EXPANSION=''
typeset -g POWERLEVEL9K_CONTEXT_ROOT_TEMPLATE='%n@%m'
typeset -g POWERLEVEL9K_CONTEXT_SUDO_TEMPLATE='%n@%m'
