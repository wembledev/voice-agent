# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/triggers/silence_trigger'

class SilenceTriggerTest < Minitest::Test
  def test_default_timeout
    trigger = SilenceTrigger.new(action: :hangup)
    assert_equal 10, trigger.timeout
  end

  def test_custom_timeout
    trigger = SilenceTrigger.new(timeout: 30, action: :hangup)
    assert_equal 30, trigger.timeout
  end

  def test_triggers_after_timeout
    trigger = SilenceTrigger.new(timeout: 5, action: :hangup)
    
    context = {
      last_response_at: Time.now - 10,  # 10 seconds ago
      is_speaking: false
    }
    
    assert_equal :hangup, trigger.check(context)
  end

  def test_does_not_trigger_before_timeout
    trigger = SilenceTrigger.new(timeout: 10, action: :hangup)
    
    context = {
      last_response_at: Time.now - 5,  # Only 5 seconds ago
      is_speaking: false
    }
    
    assert_nil trigger.check(context)
  end

  def test_does_not_trigger_during_speech
    trigger = SilenceTrigger.new(timeout: 5, action: :hangup)
    
    context = {
      last_response_at: Time.now - 60,  # Long time ago
      is_speaking: true                  # But AI is speaking
    }
    
    assert_nil trigger.check(context)
  end

  def test_does_not_trigger_without_last_response
    trigger = SilenceTrigger.new(timeout: 5, action: :hangup)
    
    context = {
      last_response_at: nil,
      is_speaking: false
    }
    
    assert_nil trigger.check(context)
  end

  def test_silence_duration_tracked
    trigger = SilenceTrigger.new(timeout: 10, action: :hangup)
    
    trigger.check(last_response_at: Time.now - 7, is_speaking: false)
    
    assert_in_delta 7, trigger.silence_duration, 0.5
  end

  def test_remaining_time
    trigger = SilenceTrigger.new(timeout: 10, action: :hangup)
    
    trigger.check(last_response_at: Time.now - 7, is_speaking: false)
    
    assert_in_delta 3, trigger.remaining, 0.5
  end

  def test_remaining_is_zero_when_exceeded
    trigger = SilenceTrigger.new(timeout: 5, action: :hangup)
    
    trigger.check(last_response_at: Time.now - 10, is_speaking: false)
    
    assert_equal 0, trigger.remaining
  end

  def test_reset_clears_duration
    trigger = SilenceTrigger.new(timeout: 10, action: :hangup)
    
    trigger.check(last_response_at: Time.now - 7, is_speaking: false)
    trigger.reset!
    
    assert_equal 0, trigger.silence_duration
  end

  def test_speaking_resets_duration
    trigger = SilenceTrigger.new(timeout: 10, action: :hangup)
    
    trigger.check(last_response_at: Time.now - 7, is_speaking: false)
    trigger.check(last_response_at: Time.now - 7, is_speaking: true)
    
    assert_equal 0, trigger.silence_duration
  end

  def test_once_is_true
    trigger = SilenceTrigger.new(action: :hangup)
    assert trigger.once?
  end

  def test_name
    trigger = SilenceTrigger.new(action: :hangup)
    assert_equal 'silence', trigger.name
  end

  def test_disabled_trigger
    trigger = SilenceTrigger.new(timeout: 1, action: :hangup, enabled: false)
    
    context = {
      last_response_at: Time.now - 60,
      is_speaking: false
    }
    
    assert_nil trigger.check(context)
  end
end
