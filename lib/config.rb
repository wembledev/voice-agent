# frozen_string_literal: true

require 'yaml'
require 'erb'

class Config
  class Error < StandardError; end

  @data = nil
  @root = File.expand_path('..', __dir__)

  class << self
    attr_writer :root

    def load!(root = nil)
      @root = root if root
      path = File.join(@root, 'config', 'default.yml')
      raise Error, "Config file not found: #{path}" unless File.exist?(path)

      yaml = ERB.new(File.read(path)).result
      @data = YAML.safe_load(yaml, permitted_classes: [Symbol])
    end

    def fetch(*keys)
      load! unless @data
      keys = keys.map(&:to_s)
      value = @data.dig(*keys)
      raise Error, "Missing config key: #{keys.join('.')}" if value.nil?
      value
    end

    def agent(name = nil)
      load! unless @data
      name = (name || @data['default_agent']).to_s
      agents = @data['agents'] || {}
      agents[name] or raise Error, "Unknown agent: #{name}. Available: #{agents.keys.join(', ')}"
    end

    def reset!
      @data = nil
      @root = File.expand_path('..', __dir__)
    end

    def loaded?
      !@data.nil?
    end
  end
end
