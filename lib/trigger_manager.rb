# frozen_string_literal: true

require_relative 'trigger'

# Coordinates multiple triggers and invokes callbacks on match.
#
# Usage:
#   manager = TriggerManager.new
#   manager.add(KeywordTrigger.new(patterns: /goodbye/i, action: :hangup))
#   manager.add(SilenceTrigger.new(timeout: 10, action: :hangup))
#   
#   manager.on(:hangup) { |ctx| sip.hangup }
#   manager.on(:delegate) { |ctx, text| ai.process(text) }
#   
#   manager.check(transcript: "goodbye", role: :user)
#   # => Fires :hangup callback if keyword matches
#
class TriggerManager
  attr_reader :triggers

  def initialize
    @triggers = []
    @callbacks = Hash.new { |h, k| h[k] = [] }
    @fired = {}  # Track which triggers have fired (prevent double-fire)
  end

  # Add a trigger to the manager.
  # @param trigger [Trigger]
  # @return [self]
  def add(trigger)
    @triggers << trigger
    self
  end

  # Remove a trigger by name or instance.
  # @param trigger [Trigger, String, Symbol]
  # @return [self]
  def remove(trigger)
    case trigger
    when Trigger
      @triggers.delete(trigger)
    when String, Symbol
      @triggers.reject! { |t| t.name == trigger.to_s }
    end
    self
  end

  # Register a callback for an action.
  # @param action [Symbol] action to listen for (:hangup, :delegate, etc.)
  # @yield [context, *args] block called when action fires
  # @return [self]
  def on(action, &block)
    @callbacks[action] << block
    self
  end

  # Check all triggers against current context.
  # Fires callbacks for any matching triggers.
  #
  # @param context [Hash] see Trigger#check for options
  # @return [Array<Symbol>] actions that were triggered
  def check(context)
    actions_fired = []

    @triggers.each do |trigger|
      next unless trigger.enabled?
      
      action = trigger.check(context)
      next unless action
      
      # Some triggers (like keyword) should only fire once per call
      trigger_key = "#{trigger.name}:#{action}"
      next if @fired[trigger_key] && trigger.respond_to?(:once?) && trigger.once?
      
      @fired[trigger_key] = true
      actions_fired << action
      
      # Invoke callbacks
      @callbacks[action].each do |callback|
        if trigger.respond_to?(:payload)
          callback.call(context, trigger.payload)
        else
          callback.call(context)
        end
      end
    end

    actions_fired
  end

  # Reset fired state (for new calls).
  def reset!
    @fired.clear
  end

  # Find trigger by name.
  # @param name [String, Symbol]
  # @return [Trigger, nil]
  def find(name)
    @triggers.find { |t| t.name == name.to_s }
  end

  # List all registered trigger names.
  # @return [Array<String>]
  def trigger_names
    @triggers.map(&:name)
  end
end
