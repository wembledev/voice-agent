# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/ai_assistant'
require_relative '../lib/ai_assistant/openclaw'

class AiAssistantTest < Minitest::Test
  def test_base_class_raises_not_implemented
    assistant = AiAssistant.new
    assert_raises(AiAssistant::NotImplementedError) { assistant.name }
    assert_raises(AiAssistant::NotImplementedError) { assistant.instructions }
    assert_raises(AiAssistant::NotImplementedError) { assistant.chat("hello") }
    assert_raises(AiAssistant::NotImplementedError) { assistant.sessions_send(intent: 'test', request: 'test') }
  end
end

class OpenClawTest < Minitest::Test
  def setup
    @assistant = AiAssistant::OpenClaw.new
  end

  def test_loads_credentials_from_env
    assert @assistant, "OpenClaw should initialize from .env.local"
  end

  def test_has_name
    assert @assistant.name.is_a?(String)
    refute @assistant.name.empty?
  end

  def test_has_instructions
    assert @assistant.instructions.is_a?(String)
    refute @assistant.instructions.empty?
  end

  def test_chat_returns_response
    skip "OPENCLAW_API_KEY not set" unless @assistant.configured?
    reply = @assistant.chat("Say hello in exactly three words.")
    assert reply.is_a?(String), "Chat should return a string"
    refute reply.empty?, "Chat should return a non-empty response"
  end

  def test_sessions_send_returns_response
    skip "OPENCLAW_API_KEY not set" unless @assistant.configured?
    reply = @assistant.sessions_send(intent: 'test', request: 'This is a test delegation.')
    assert reply.is_a?(String), "sessions_send should return a string"
    refute reply.empty?, "sessions_send should return a non-empty response"
  end
end
