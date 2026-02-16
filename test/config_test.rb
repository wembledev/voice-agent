# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/config'
require 'tmpdir'
require 'fileutils'

class ConfigTest < Minitest::Test
  def setup
    Config.reset!
  end

  def teardown
    Config.reset!
  end

  def test_load_parses_yaml
    Config.load!
    assert Config.loaded?
  end

  def test_fetch_returns_nested_value
    Config.load!
    assert_equal 'baresip', Config.fetch(:sip, :client)
  end

  def test_fetch_raises_on_missing_key
    Config.load!
    assert_raises(Config::Error) { Config.fetch(:nonexistent, :key) }
  end

  def test_fetch_auto_loads
    refute Config.loaded?
    Config.fetch(:sip, :client)
    assert Config.loaded?
  end

  def test_fetch_with_string_keys
    Config.load!
    assert_equal 'baresip', Config.fetch('sip', 'client')
  end

  def test_agent_returns_default
    Config.load!
    profile = Config.agent
    assert_equal 'Ara', profile['name']
    assert_equal 'Ara', profile['voice']
    assert_includes profile['personality'], 'cheeky'
  end

  def test_agent_returns_named_profile
    Config.load!
    profile = Config.agent('jarvis')
    assert_equal 'Jarvis', profile['name']
    assert_equal 'Rex', profile['voice']
    assert_includes profile['personality'], 'British'
  end

  def test_agent_raises_on_unknown
    Config.load!
    assert_raises(Config::Error) { Config.agent('nonexistent') }
  end

  def test_reset_clears_state
    Config.load!
    assert Config.loaded?
    Config.reset!
    refute Config.loaded?
  end

  def test_erb_interpolation
    skip "SIP_SERVER not set" unless ENV['SIP_SERVER']
    # SIP credentials come from ENV via ERB
    Config.load!
    sip_server = Config.fetch(:sip, :server)
    # Value should match ENV['SIP_SERVER'] (set by dotenv in .env.local)
    assert_equal ENV['SIP_SERVER'], sip_server
  end

  def test_load_raises_on_missing_file
    Config.root = Dir.tmpdir
    assert_raises(Config::Error) { Config.load! }
  end

  def test_load_with_custom_root
    # Create a temp config
    dir = Dir.mktmpdir
    config_dir = File.join(dir, 'config')
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, 'default.yml'), <<~YAML)
      sip:
        client: test_client
      agents:
        test:
          name: Test
          voice: Rex
          personality: A test agent.
      default_agent: test
    YAML

    Config.load!(dir)
    assert_equal 'test_client', Config.fetch(:sip, :client)
    profile = Config.agent
    assert_equal 'Test', profile['name']
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
