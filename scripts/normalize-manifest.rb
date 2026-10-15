#!/usr/bin/env ruby
# Normalise a multi-document Kubernetes manifest so two renders can be diffed.
#
# A template refactor is supposed to change nothing about the rendered object -
# a model pod template that changes is a rollout, and these pods hold a GPU.
# Byte diffs of `helm template` output cannot answer that: whitespace and key
# order move without the object moving. This parses every document and emits them
# sorted by kind/name, so `diff before after` answers the only question that
# matters - did anything the API server would notice change?
#
#   helm template ai k8s/apps/ai -f ... | ./scripts/normalize-manifest.rb > after.json
require "yaml"
require "json"

docs = YAML.load_stream(STDIN.read).compact
docs.sort_by! { |d| [d["kind"].to_s, d.dig("metadata", "name").to_s, d.dig("metadata", "namespace").to_s] }
$stderr.puts "#{docs.size} document(s)"
puts JSON.pretty_generate(docs)
