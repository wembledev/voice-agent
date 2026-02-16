# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/triggers'

class TriggerManagerTest < Minitest::Test
  def setup
    @manager = TriggerManager.new
  end

  def test_add_trigger
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test)
    @manager.add(trigger)
    
    assert_includes @manager.triggers, trigger
    assert_includes @manager.trigger_names, 'keyword'
  end

  def test_remove_trigger_by_instance
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test)
    @manager.add(trigger)
    @manager.remove(trigger)
    
    refute_includes @manager.triggers, trigger
  end

  def test_remove_trigger_by_name
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test)
    @manager.add(trigger)
    @manager.remove(:keyword)
    
    refute_includes @manager.triggers, trigger
  end

  def test_find_trigger
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test)
    @manager.add(trigger)
    
    assert_equal trigger, @manager.find(:keyword)
    assert_nil @manager.find(:nonexistent)
  end

  def test_check_fires_callback
    fired = false
    context_received = nil
    
    @manager.add(KeywordTrigger.new(patterns: /goodbye/i, action: :hangup))
    @manager.on(:hangup) do |ctx|
      fired = true
      context_received = ctx
    end
    
    ctx = { transcript: 'Goodbye!', role: :user }
    actions = @manager.check(ctx)
    
    assert fired
    assert_equal ctx, context_received
    assert_includes actions, :hangup
  end

  def test_check_does_not_fire_when_no_match
    fired = false
    
    @manager.add(KeywordTrigger.new(patterns: /goodbye/i, action: :hangup))
    @manager.on(:hangup) { fired = true }
    
    @manager.check(transcript: 'Hello!', role: :user)
    
    refute fired
  end

  def test_multiple_callbacks_for_same_action
    count = 0
    
    @manager.add(KeywordTrigger.new(patterns: /test/i, action: :test))
    @manager.on(:test) { count += 1 }
    @manager.on(:test) { count += 1 }
    
    @manager.check(transcript: 'test', role: :user)
    
    assert_equal 2, count
  end

  def test_once_trigger_fires_only_once
    count = 0
    
    @manager.add(KeywordTrigger.new(patterns: /goodbye/i, action: :hangup, once: true))
    @manager.on(:hangup) { count += 1 }
    
    @manager.check(transcript: 'goodbye', role: :user)
    @manager.check(transcript: 'goodbye again', role: :user)
    
    assert_equal 1, count
  end

  def test_reset_clears_fired_state
    count = 0
    
    @manager.add(KeywordTrigger.new(patterns: /goodbye/i, action: :hangup, once: true))
    @manager.on(:hangup) { count += 1 }
    
    @manager.check(transcript: 'goodbye', role: :user)
    @manager.reset!
    @manager.check(transcript: 'goodbye', role: :user)
    
    assert_equal 2, count
  end

  def test_disabled_trigger_does_not_fire
    fired = false
    
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test, enabled: false)
    @manager.add(trigger)
    @manager.on(:test) { fired = true }
    
    @manager.check(transcript: 'test', role: :user)
    
    refute fired
  end

  def test_payload_passed_to_callback
    payload_received = nil

    @manager.add(RequestCapture.new(prefix: /hey garbo,?\s*/i, action: :delegate))
    @manager.on(:delegate) { |_ctx, payload| payload_received = payload }

    @manager.check(transcript: 'Hey Garbo, send a text', role: :user)

    assert_equal 'send a text', payload_received
  end

  def test_delegation_trigger_fires_on_tool_call
    payload_received = nil

    @manager.add(DelegationTrigger.new)
    @manager.on(:delegate) { |_ctx, payload| payload_received = payload }

    actions = @manager.check(
      tool_name: 'classify_intent',
      tool_arguments: '{"intent":"send_text","request":"text mom"}',
      tool_call_id: 'call_99'
    )

    assert_includes actions, :delegate
    assert_equal 'send_text', payload_received['intent']
    assert_equal 'text mom', payload_received['request']
  end

  def test_mixed_triggers_independent
    hangup_fired = false
    delegate_fired = false

    @manager.add(KeywordTrigger.new(action: :hangup))
    @manager.add(DelegationTrigger.new)
    @manager.on(:hangup) { hangup_fired = true }
    @manager.on(:delegate) { delegate_fired = true }

    # Tool call context should not fire keyword trigger
    @manager.check(tool_name: 'classify_intent', tool_arguments: '{}', tool_call_id: 'c1')
    refute hangup_fired
    assert delegate_fired

    # Keyword context should not fire delegation trigger
    delegate_fired = false
    @manager.check(transcript: 'goodbye', role: :user)
    assert hangup_fired
    refute delegate_fired
  end
end
