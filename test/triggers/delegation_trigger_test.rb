# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/triggers/delegation_trigger'

class DelegationTriggerTest < Minitest::Test
  def test_default_tool_name
    trigger = DelegationTrigger.new
    assert_equal 'classify_intent', trigger.tool
  end

  def test_default_action_is_delegate
    trigger = DelegationTrigger.new
    assert_equal :delegate, trigger.action
  end

  def test_fires_on_matching_tool
    trigger = DelegationTrigger.new

    result = trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: { 'intent' => 'send_text', 'request' => 'send a text to mom' },
      tool_call_id: 'call_123'
    )

    assert_equal :delegate, result
  end

  def test_does_not_fire_on_different_tool
    trigger = DelegationTrigger.new

    result = trigger.check(
      tool_name: 'other_tool',
      tool_arguments: '{}',
      tool_call_id: 'call_123'
    )

    assert_nil result
  end

  def test_payload_contains_hash_arguments
    trigger = DelegationTrigger.new

    trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: { 'intent' => 'set_reminder', 'request' => 'remind me at 5pm' },
      tool_call_id: 'call_456'
    )

    assert_equal({ 'intent' => 'set_reminder', 'request' => 'remind me at 5pm' }, trigger.payload)
  end

  def test_payload_parses_json_string_arguments
    trigger = DelegationTrigger.new

    trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: '{"intent":"check_weather","request":"what is the weather"}',
      tool_call_id: 'call_789'
    )

    assert_equal 'check_weather', trigger.payload['intent']
    assert_equal 'what is the weather', trigger.payload['request']
  end

  def test_payload_handles_invalid_json
    trigger = DelegationTrigger.new

    trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: 'not json at all',
      tool_call_id: 'call_bad'
    )

    assert_equal({ 'raw' => 'not json at all' }, trigger.payload)
  end

  def test_call_id_stored
    trigger = DelegationTrigger.new

    trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: '{}',
      tool_call_id: 'call_abc'
    )

    assert_equal 'call_abc', trigger.call_id
  end

  def test_no_match_without_tool_name
    trigger = DelegationTrigger.new

    assert_nil trigger.check(transcript: 'hello', role: :user)
    assert_nil trigger.check({})
  end

  def test_no_match_when_tool_name_nil
    trigger = DelegationTrigger.new

    assert_nil trigger.check(tool_name: nil)
  end

  def test_once_is_false
    trigger = DelegationTrigger.new
    refute trigger.once?
  end

  def test_name
    trigger = DelegationTrigger.new
    assert_equal 'delegation', trigger.name
  end

  def test_disabled_trigger
    trigger = DelegationTrigger.new(enabled: false)

    assert_nil trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: '{}',
      tool_call_id: 'call_123'
    )
  end

  def test_custom_tool_name
    trigger = DelegationTrigger.new(tool: 'route_request')

    assert_nil trigger.check(tool_name: 'classify_intent', tool_arguments: '{}', tool_call_id: 'c1')
    assert_equal :delegate, trigger.check(tool_name: 'route_request', tool_arguments: '{}', tool_call_id: 'c2')
  end

  def test_custom_action
    trigger = DelegationTrigger.new(action: :forward)
    assert_equal :forward, trigger.action

    result = trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: '{}',
      tool_call_id: 'call_123'
    )
    assert_equal :forward, result
  end

  def test_nil_arguments_gives_empty_payload
    trigger = DelegationTrigger.new

    trigger.check(
      tool_name: 'classify_intent',
      tool_arguments: nil,
      tool_call_id: 'call_nil'
    )

    assert_equal({}, trigger.payload)
  end
end
