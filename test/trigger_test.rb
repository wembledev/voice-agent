# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/trigger'

class TriggerTest < Minitest::Test
  def test_base_class_raises_on_check
    trigger = Trigger.new(action: :test)
    assert_raises(Trigger::Error) { trigger.check({}) }
  end

  def test_enabled_by_default
    trigger = Trigger.new(action: :test)
    assert trigger.enabled?
  end

  def test_can_be_disabled
    trigger = Trigger.new(action: :test, enabled: false)
    refute trigger.enabled?
  end

  def test_enable_disable_toggle
    trigger = Trigger.new(action: :test)
    
    trigger.disable!
    refute trigger.enabled?
    
    trigger.enable!
    assert trigger.enabled?
  end

  def test_name_strips_trigger_suffix
    # Create a simple subclass for testing
    klass = Class.new(Trigger) do
      def check(_); nil; end
    end
    Object.const_set(:FooBarTrigger, klass)
    
    trigger = FooBarTrigger.new(action: :test)
    assert_equal 'foobar', trigger.name
  ensure
    Object.send(:remove_const, :FooBarTrigger)
  end
end
