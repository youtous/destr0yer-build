# name: Gianu (from https://github.com/oh-my-fish/theme-gianu/blob/master/fish_prompt.fish)
#  47e30dc on 6 Jan 2019

function _git_branch_name
  echo (command git symbolic-ref HEAD 2> /dev/null | sed -e 's|^refs/heads/||')
end

function _is_git_dirty
  echo (command git status -s --ignore-submodules=dirty 2> /dev/null)
end

function fish_prompt
  set -l cyan (set_color cyan)
  set -l yellow (set_color -o yellow)
  set -l red (set_color -o red)
  set -l green (set_color -o green)
  set -l white (set_color -o white)
  set -l normal (set_color normal)


  set -l cwd $cyan(basename (prompt_pwd))

  if [ (_git_branch_name) ]
    set -l git_branch $green(_git_branch_name)
    set git_info "$normal($green$git_branch"

    if [ (_is_git_dirty) ]
      set -l dirty "$yellow ✗"
      set git_info "$git_info$dirty"
    end

    set git_info "$git_info$normal)"
  end

  # register server_environment
  set -l server_environment (cat /etc/server_environment || echo "unknown")

  # register end of prompt
  set -l additional_prompt ""

  # define hostname_color and after tag
  set -l hostname_color (set_color normal)
  if test "$server_environment" = "dev"
      set hostname_color (set_color -o cyan)
  else if test "$server_environment" = "test"
      set hostname_color (set_color -o green)
  else if test "$server_environment" = "prod"
      set hostname_color (set_color -o red)
      set additional_prompt (set_color yellow)"{PROD}"
  end

  set -l colored_hostname $hostname_color(hostname -s)

  # define ending tag for root user
  set -l ending_tag '$'
  if test (id -u) = "0"
    set ending_tag '#'
  end

  echo -n -s $normal '[' $white (whoami) $normal '@' $colored_hostname $normal ' ' $cwd ' '  $git_info $normal ']'$additional_prompt''$normal$ending_tag' '
end
