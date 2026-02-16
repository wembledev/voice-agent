# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/triggers/keyword_trigger'

class KeywordTriggerTest < Minitest::Test
  def test_default_farewell_patterns
    trigger = KeywordTrigger.new(action: :hangup)
    
    # Should match common farewells
    assert_equal :hangup, trigger.check(transcript: 'goodbye', role: :user)
    assert_equal :hangup, trigger.check(transcript: 'bye', role: :user)
    assert_equal :hangup, trigger.check(transcript: 'see you later', role: :user)
    assert_equal :hangup, trigger.check(transcript: 'take care', role: :user)
    assert_equal :hangup, trigger.check(transcript: 'gotta go', role: :user)
    
    # Should not match non-farewells
    assert_nil trigger.check(transcript: 'hello', role: :user)
    assert_nil trigger.check(transcript: 'how are you', role: :user)
  end

  def test_custom_regex_pattern
    trigger = KeywordTrigger.new(patterns: /\bhelp\b/i, action: :assist)
    
    assert_equal :assist, trigger.check(transcript: 'I need help', role: :user)
    assert_nil trigger.check(transcript: 'hello', role: :user)
  end

  def test_custom_string_pattern
    trigger = KeywordTrigger.new(patterns: 'stop', action: :stop)
    
    assert_equal :stop, trigger.check(transcript: 'please stop', role: :user)
    assert_nil trigger.check(transcript: 'stopper', role: :user)  # Word boundary
  end

  def test_custom_array_pattern
    trigger = KeywordTrigger.new(patterns: %w[red blue green], action: :color)
    
    assert_equal :color, trigger.check(transcript: 'I like red', role: :user)
    assert_equal :color, trigger.check(transcript: 'blue is nice', role: :user)
    assert_nil trigger.check(transcript: 'yellow', role: :user)
  end

  def test_role_filter
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test, role: :user)
    
    assert_equal :test, trigger.check(transcript: 'test', role: :user)
    assert_nil trigger.check(transcript: 'test', role: :assistant)
  end

  def test_no_role_filter
    trigger = KeywordTrigger.new(patterns: /test/i, action: :test, role: nil)
    
    assert_equal :test, trigger.check(transcript: 'test', role: :user)
    assert_equal :test, trigger.check(transcript: 'test', role: :assistant)
  end

  def test_empty_transcript
    trigger = KeywordTrigger.new(action: :hangup)
    
    assert_nil trigger.check(transcript: '', role: :user)
    assert_nil trigger.check(transcript: nil, role: :user)
  end

  def test_matched_attribute
    trigger = KeywordTrigger.new(action: :hangup)
    
    trigger.check(transcript: 'Okay, goodbye!', role: :user)
    assert_equal 'goodbye', trigger.matched
  end

  def test_case_insensitive_by_default
    trigger = KeywordTrigger.new(patterns: /goodbye/i, action: :hangup)
    
    assert_equal :hangup, trigger.check(transcript: 'GOODBYE', role: :user)
    assert_equal :hangup, trigger.check(transcript: 'Goodbye', role: :user)
  end

  def test_once_by_default
    trigger = KeywordTrigger.new(action: :hangup)
    assert trigger.once?
  end

  def test_name
    trigger = KeywordTrigger.new(action: :test)
    assert_equal 'keyword', trigger.name
  end

  def test_disabled_trigger
    trigger = KeywordTrigger.new(action: :hangup, enabled: false)
    assert_nil trigger.check(transcript: 'goodbye', role: :user)
  end
end
