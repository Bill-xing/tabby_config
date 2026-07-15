#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TABBY_CONFIG="$REPO_ROOT/config/tabby/config.yaml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$actual" = "$expected" ] || fail "$message: expected '$expected', got '$actual'"
}

ruby - "$TABBY_CONFIG" <<'RUBY'
require "yaml"
require "json"
require "digest"

path = ARGV.fetch(0)
raw_config = File.binread(path)

def assert(condition, message)
  raise message unless condition
end

canonical_config = raw_config.gsub("\r\n", "\n")
assert(
  !canonical_config.include?("\r"),
  "public Tabby snapshot contains unsupported bare CR line endings",
)
snapshot_digest = Digest::SHA256.hexdigest(canonical_config)
assert(
  snapshot_digest == "7ff19c05e513d74db10be6a7f888313ea5a66acb1cda858fedbd2ce69d86e137",
  "public Tabby snapshot bytes changed: #{snapshot_digest}",
)
config = YAML.safe_load(canonical_config, aliases: false)

allowed_root_keys = %w[
  version
  profiles
  groups
  hotkeys
  terminal
  clickableLinks
  accessibility
  appearance
  hacks
  providerBlacklist
  commandBlacklist
  profileBlacklist
  enableWelcomeTab
  pluginBlacklist
  profileDefaults
]

assert(config.is_a?(Hash), "Tabby config root must be a mapping")
missing_root_keys = allowed_root_keys - config.keys
unexpected_root_keys = config.keys - allowed_root_keys
assert(
  missing_root_keys.empty? && unexpected_root_keys.empty?,
  "root key mismatch: missing #{missing_root_keys.inspect}, unexpected #{unexpected_root_keys.inspect}",
)
assert(config["version"] == 8, "version must be 8")
assert(config["profiles"] == [], "profiles must be empty")
assert(config["groups"] == [], "groups must be empty")
assert(!config.key?("ssh"), "root ssh state must not be tracked")
assert(!config.key?("configSync"), "configSync must not be tracked")
assert(!config.key?("vault"), "vault must not be tracked")

hotkeys = config.fetch("hotkeys")
assert(hotkeys.length == 103, "expected 103 hotkey actions")
hotkey_digest = Digest::SHA256.hexdigest(JSON.generate(hotkeys))
assert(
  hotkey_digest == "0c312163f4f17cf825ebca74843c672e54a8d37c46e6f59b1c4e2c25b56f606c",
  "hotkey snapshot digest changed",
)

terminal = config.fetch("terminal")
assert(terminal["fontSize"] == 20, "fontSize must be 20")
assert(terminal.dig("colorScheme", "name") == "AdventureTime", "dark scheme must be AdventureTime")
assert(
  terminal.dig("colorScheme", "colors") == [
    "#050404", "#bd0013", "#4ab118", "#e7741e",
    "#0f4ac6", "#665993", "#70a598", "#f8dcc0",
    "#4e7cbf", "#fc5f5a", "#9eff6e", "#efc11a",
    "#1997c6", "#9b5953", "#c8faf4", "#f6f5fb",
  ],
  "AdventureTime palette changed",
)
assert(
  terminal.dig("lightColorScheme", "name") == "Tabby Default Light",
  "light scheme must be Tabby Default Light",
)
assert(
  terminal.dig("lightColorScheme", "colors").length == 16,
  "light palette must contain 16 colors",
)
assert(terminal["customColorSchemes"] == [], "customColorSchemes must be empty")

assert(config.dig("appearance", "opacity") == 0.84, "opacity must be 0.84")
assert(config.dig("appearance", "vibrancy") == true, "vibrancy must be enabled")
assert(config["enableWelcomeTab"] == false, "welcome tab must be disabled")
assert(
  config.dig("profileDefaults", "ssh", "disableDynamicTitle") == true,
  "SSH dynamic titles must be disabled by default",
)

forbidden_keys = %w[
  knownHosts
  token
  password
  passphrase
  privateKey
  privateKeys
  vault
  configSync
]
forbidden_paths = []
string_values = []

walk = lambda do |value, path_parts|
  case value
  when Hash
    value.each do |key, child|
      child_path = path_parts + [key]
      forbidden_paths << child_path.join(".") if forbidden_keys.include?(key)
      walk.call(child, child_path)
    end
  when Array
    value.each_with_index { |child, index| walk.call(child, path_parts + [index.to_s]) }
  when String
    string_values << value
  end
end
walk.call(config, [])

assert(forbidden_paths.empty?, "forbidden keys found: #{forbidden_paths.inspect}")
assert(
  string_values.none? { |value| value.match?(/\b(?:\d{1,3}\.){3}\d{1,3}\b/) },
  "IPv4 address found in public config",
)

puts "tabby config content and privacy checks passed"
RUBY
