# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/voice_agent'
require_relative '../lib/voice_agent/grok'

class VoiceAgentTest < Minitest::Test
  def test_base_class_raises_not_implemented
    agent = VoiceAgent.new
    assert_raises(VoiceAgent::Error) { agent.connect }
    assert_raises(VoiceAgent::Error) { agent.send_audio("data") }
    assert_raises(VoiceAgent::Error) { agent.send_text("hello") }
    assert_raises(VoiceAgent::Error) { agent.disconnect }
  end

  def test_base_class_not_connected_by_default
    agent = VoiceAgent.new
    refute agent.connected?
  end
end

class GrokTest < Minitest::Test
  def setup
    @agent = VoiceAgent::Grok.new(
      instructions: 'Test agent',
      voice: 'Rex'
    )
  end

  def test_initializes_from_env
    assert @agent, "Grok should initialize from .env.local"
  end

  def test_not_connected_before_connect
    refute @agent.connected?
  end

  def test_send_audio_noop_when_disconnected
    # Should not raise, just silently return
    @agent.send_audio("fake audio data")
  end

  def test_send_text_noop_when_disconnected
    @agent.send_text("hello")
  end

  def test_send_tool_result_noop_when_disconnected
    @agent.send_tool_result('call_123', 'result')
  end

  def test_classify_intent_tool_defined
    tool = VoiceAgent::Grok::CLASSIFY_INTENT_TOOL
    assert tool
    assert_equal 'function', tool[:type]
    assert_equal 'classify_intent', tool[:name]
    assert tool[:parameters][:properties][:intent]
    assert tool[:parameters][:properties][:request]
    assert_includes tool[:parameters][:required], 'intent'
    assert_includes tool[:parameters][:required], 'request'
  end

  def test_tools_config
    agent = VoiceAgent::Grok.new(
      tools: [VoiceAgent::Grok::CLASSIFY_INTENT_TOOL]
    )
    assert agent
    refute agent.connected?
  end

  def test_connect_and_disconnect
    # Integration test — actually connects to Grok API
    connected = false
    session_updated = false

    @agent.connect(
      on_ready: -> { connected = true },
      on_session: ->(e) { session_updated = true if e['type'] == 'session.updated' }
    )

    # Wait for connection
    5.times do
      break if session_updated
      sleep 1
    end

    assert connected, "Should connect to Grok"
    assert session_updated, "Should receive session.updated"
    assert @agent.connected?

    @agent.disconnect
    sleep 0.5
    refute @agent.connected?
  end
end
