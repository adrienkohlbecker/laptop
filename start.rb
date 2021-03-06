#!/usr/bin/env ruby

LAPTOP_PATH = ENV.fetch('LAPTOP_PATH', "#{Dir.home}/Desktop/laptop")
LAPTOP_REPO = ENV.fetch('LAPTOP_REPO', 'https://github.com/adrienkohlbecker/laptop.git')
LAPTOP_REPO_BRANCH = ENV.fetch('LAPTOP_REPO_BRANCH', 'master')
DOTFILES_PATH = ENV.fetch('DOTFILES_PATH', "#{Dir.home}/.dotfiles")
DOTFILES_REPO = ENV.fetch('DOTFILES_REPO', 'https://github.com/adrienkohlbecker/dotfiles.git')
DOTFILES_REPO_BRANCH = ENV.fetch('DOTFILES_REPO_BRANCH', 'master')

module Tty extend self
  def blue; bold 34; end
  def green; bold 32; end
  def white; bold 39; end
  def red; underline 31; end
  def reset; escape 0; end
  def bold n; escape "1;#{n}" end
  def underline n; escape "4;#{n}" end
  def escape n; "\033[#{n}m" if STDOUT.tty? end
end

class Array
  def shell_s
    cp = dup
    first = cp.shift
    cp.map { |arg| arg.gsub ' ', '\\ ' }.unshift(first) * ' '
  end
end

def ohai *args
  puts "#{Tty.blue}==>#{Tty.white} #{args.shell_s}#{Tty.reset}"
end

def ohai_command(*args)
  puts "  #{Tty.green}> #{args.shell_s}#{Tty.reset}"
end

def warn(warning)
  puts "#{Tty.red}Warning#{Tty.reset}: #{warning.chomp}"
end

def system(*args)
  abort "Failed with #{$CHILD_STATUS} during: #{args.shell_s}" unless Kernel.system(*args)
end

def warnandexit(message)
  warn message
  exit
end

def prompt(default, *args)
  print(*args)
  print ': '
  result = gets.strip
  result.empty? ? default : result
end

def sudo(*args)
  args = if args.length > 1
           args.unshift('/usr/bin/sudo')
         else
           "/usr/bin/sudo #{args.first}"
         end
  ohai_command(*args)
  system(*args)
end

def normaldo(*args)
  ohai_command(*args)
  system(*args)
end

def macos_version
  @macos_version ||= `/usr/bin/sw_vers -productVersion`.chomp[/10\.\d+/]
end

def command?(name)
  `which #{name}`.length > 0
end

###########################################

abort "Don't run this as root!" if Process.uid == 0
abort "This script requires the user #{ENV['USER']} to be an Administrator." unless `groups`.split.include? 'admin'

ohai 'This script will setup:'
puts '  - FileVault if not already enabled'
puts '  - Command Line Tools if they are not installed'
puts '  - Ansible'
puts '  - All applications and settings from the playbook'
puts ''

if `fdesetup status`.include? 'is Off'
  ohai 'Enabling FileVault...'
  sudo 'fdesetup enable -forcerestart'
  warnandexit 'FileVault is enabled. Please restart the computer and relaunch this script.'
else
  ohai 'FileVault is enabled. Continuing...'
end

if File.exist? '/Library/Developer/CommandLineTools/usr/bin/clang'
  ohai 'XCode Command Line Tools are installed. Continuing...'
else
  ohai 'Installing the Command Line Tools (expect a GUI popup):'
  sudo '/usr/bin/xcode-select', '--install'
  warnandexit 'Relaunch this script when the installation has completed.'
end

# if command? 'xcodebuild'
#   ohai 'Xcode is installed. Asking for licence...'
#   sudo 'xcodebuild -license accept'
# else
#   ohai 'Xcode is not installed'
# end

if File.directory?(LAPTOP_PATH) && File.directory?("#{LAPTOP_PATH}/.git")
  ohai 'Updating existing laptop installation...'
  Dir.chdir LAPTOP_PATH
  normaldo 'git pull'
  normaldo "git checkout #{LAPTOP_REPO_BRANCH}"
else
  ohai 'Setting up the laptop installation...'
  sudo "mkdir -p #{LAPTOP_PATH}"
  sudo "chown -R #{ENV['USER']} #{LAPTOP_PATH}"
  normaldo "git clone -q #{LAPTOP_REPO} #{LAPTOP_PATH} -b #{LAPTOP_REPO_BRANCH}"
  Dir.chdir LAPTOP_PATH
end

if File.directory?("#{Dir.home}/.oh-my-zsh")
  ohai "Oh My ZSH is installed"
else
  normaldo 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"'
end

if File.directory?(DOTFILES_PATH)
 ohai 'Updating existing dotfiles installation...'
 normaldo "git --git-dir=#{Dir.home}/.dotfiles --work-tree=#{Dir.home} pull"
 normaldo "git --git-dir=#{Dir.home}/.dotfiles --work-tree=#{Dir.home} checkout #{DOTFILES_REPO_BRANCH}"
else
 ohai 'Setting up the dotfiles installation...'
 normaldo "git clone -q --separate-git-dir=#{DOTFILES_PATH} #{DOTFILES_REPO} #{Dir.home}/temp-dotfikes -b #{DOTFILES_REPO_BRANCH}"
 normaldo "git --git-dir=#{Dir.home}/.dotfiles --work-tree=#{Dir.home} reset --hard"
 normaldo "rm -rf #{Dir.home}/temp-dotfikes"
end

Dir.chdir(LAPTOP_PATH)

if command? 'pip'
  ohai 'pip is installed. Continuing...'
else
  ohai 'Installing pip...'
  normaldo "curl -fsSL https://bootstrap.pypa.io/get-pip.py > /tmp/get-pip.py"
  sudo "python /tmp/get-pip.py"
end

if command? 'ansible'
  ohai 'Ansible is installed. Continuing...'
else
  ohai 'Installing ansible...'
  sudo 'pip install ansible'
end

git_user_name = `git config -f #{Dir.home}/.gitconfig.local user.name`
git_user_email = `git config -f #{Dir.home}/.gitconfig.local user.email`

if git_user_name != '' && git_user_email != ''
  ohai 'Git is already configured. Continuing...'
else
  ohai 'Asking for Git configuration'

  if git_user_name == ''

    while git_user_name == ''
      git_user_name = prompt('', 'Your GIT full name (eg: John Doe)')
      if git_user_name == ''
        warn 'Should not be empty'
      end
    end

    normaldo "git config -f #{Dir.home}/.gitconfig.local --add user.name '#{git_user_name}'"

  end

  if git_user_email == ''

    while git_user_email == ''
      git_user_email = prompt('', 'Your GIT email (eg: john@doe.com)')
      if git_user_email == ''
        warn 'Should not be empty'
      end
    end

    normaldo "git config -f #{Dir.home}/.gitconfig.local --add user.email '#{git_user_email}'"

  end
end

ohai 'Running ansible playbook'
normaldo 'ansible-playbook -i hosts.ini site.yml --ask-become-pass'

ohai 'Done!'
