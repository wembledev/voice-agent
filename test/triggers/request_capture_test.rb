# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/triggers/request_capture'

class RequestCaptureTest < Minitest::Test
  def test_default_prefixes
    trigger = RequestCapture.new
    
    assert_equal :delegate, trigger.check(transcript: 'Hey Garbo, send a text', role: :user)
    assert_equal :delegate, trigger.check(transcript: 'Garbo, can you check email', role: :user)
    assert_equal :delegate, trigger.check(transcript: 'Garbo, please remind me', role: :user)
    assert_equal :delegate, trigger.check(transcript: 'Garbo what time is it', role: :user)
  end

  def test_payload_extracted
    trigger = RequestCapture.new
    
    trigger.check(transcript: 'Hey Garbo, send a text to mom', role: :user)
    assert_equal 'send a text to mom', trigger.payload
    
    trigger.check(transcript: 'Garbo, can you check the weather', role: :user)
    assert_equal 'check the weather', trigger.payload
  end

  def test_request_text_alias
    trigger = RequestCapture.new
    
    trigger.check(transcript: 'Hey Garbo, what time is it', role: :user)
    assert_equal 'what time is it', trigger.request_text
  end

  def test_custom_prefix
    trigger = RequestCapture.new(prefix: /hey\s+assistant[,.]?\s*/i)
    
    assert_equal :delegate, trigger.check(transcript: 'Hey Assistant, help me', role: :user)
    assert_nil trigger.check(transcript: 'Hey Garbo, help me', role: :user)
  end

  def test_multiple_prefixes
    trigger = RequestCapture.new(prefixes: [
      /hey\s+garbo[,.]?\s*/i,
      /yo\s+garbo[,.]?\s*/i
    ])
    
    assert_equal :delegate, trigger.check(transcript: 'Hey Garbo, test', role: :user)
    assert_equal :delegate, trigger.check(transcript: 'Yo Garbo, test', role: :user)
  end

  def test_role_filter
    trigger = RequestCapture.new(role: :user)
    
    assert_equal :delegate, trigger.check(transcript: 'Hey Garbo, test', role: :user)
    assert_nil trigger.check(transcript: 'Hey Garbo, test', role: :assistant)
  end

  def test_no_match_without_prefix
    trigger = RequestCapture.new
    
    assert_nil trigger.check(transcript: 'send a text to mom', role: :user)
    assert_nil trigger.check(transcript: 'what time is it', role: :user)
  end

  def test_empty_request_after_prefix
    trigger = RequestCapture.new
    
    # Just the prefix with nothing after - should not trigger
    assert_nil trigger.check(transcript: 'Hey Garbo,', role: :user)
    assert_nil trigger.check(transcript: 'Hey Garbo', role: :user)
  end

  def test_empty_transcript
    trigger = RequestCapture.new
    
    assert_nil trigger.check(transcript: '', role: :user)
    assert_nil trigger.check(transcript: nil, role: :user)
  end

  def test_case_insensitive
    trigger = RequestCapture.new
    
    assert_equal :delegate, trigger.check(transcript: 'HEY GARBO, test', role: :user)
    assert_equal :delegate, trigger.check(transcript: 'hey garbo, test', role: :user)
  end

  def test_default_action_is_delegate
    trigger = RequestCapture.new
    assert_equal :delegate, trigger.action
  end

  def test_custom_action
    trigger = RequestCapture.new(action: :forward)
    assert_equal :forward, trigger.action
    
    assert_equal :forward, trigger.check(transcript: 'Hey Garbo, test', role: :user)
  end

  def test_once_is_false
    trigger = RequestCapture.new
    refute trigger.once?
  end

  def test_name
    trigger = RequestCapture.new
    assert_equal 'request', trigger.name
  end

  def test_disabled_trigger
    trigger = RequestCapture.new(enabled: false)
    assert_nil trigger.check(transcript: 'Hey Garbo, test', role: :user)
  end

  def test_with_comma_variation
    trigger = RequestCapture.new
    
    trigger.check(transcript: 'Hey Garbo, send message', role: :user)
    assert_equal 'send message', trigger.payload
    
    trigger.check(transcript: 'Hey Garbo send message', role: :user)
    assert_equal 'send message', trigger.payload
  end
end
