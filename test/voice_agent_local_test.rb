# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/voice_agent/local'
require_relative '../lib/audio_bridge'

class VoiceAgentLocalTest < Minitest::Test
  def test_initialization
    agent = VoiceAgent::Local.new(
      api_key: 'test-key',
      voice: 'eric',
      agent_name: 'TestAgent',
      instructions: 'You are a test agent.',
      trump: true,
      verbose: false
    )

    refute agent.connected?
  end

  def test_inherits_voice_agent
    agent = VoiceAgent::Local.new(api_key: 'test-key')
    assert_kind_of VoiceAgent, agent
  end

  def test_default_config
    ENV['XAI_API_KEY'] = 'test-key'
    agent = VoiceAgent::Local.new
    refute agent.connected?
  ensure
    ENV.delete('XAI_API_KEY')
  end

  def test_missing_api_key_raises
    original = ENV.delete('XAI_API_KEY')
    assert_raises(RuntimeError) { VoiceAgent::Local.new }
  ensure
    ENV['XAI_API_KEY'] = original if original
  end

  def test_subprocess_paths_exist
    assert File.exist?(VoiceAgent::Local::VENV_PYTHON),
           "Python venv not found at #{VoiceAgent::Local::VENV_PYTHON}"
    assert File.exist?(VoiceAgent::Local::TTS_SCRIPT),
           "TTS script not found at #{VoiceAgent::Local::TTS_SCRIPT}"
    assert File.exist?(VoiceAgent::Local::STT_SCRIPT),
           "STT script not found at #{VoiceAgent::Local::STT_SCRIPT}"
  end

  def test_boundary_sentinel_matches_python
    # The Ruby sentinel must match the Python UTTERANCE_BOUNDARY (0xDEADBEEF LE)
    sentinel = VoiceAgent::Local::BOUNDARY_SENTINEL
    assert_equal 4, sentinel.bytesize
    assert_equal "\xEF\xBE\xAD\xDE".b, sentinel
  end

  def test_ref_audio_config
    agent = VoiceAgent::Local.new(
      api_key: 'test-key',
      ref_audio: '/tmp/trump.wav',
      ref_text: 'Hello world'
    )
    refute agent.connected?
  end
end
