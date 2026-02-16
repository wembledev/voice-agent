# frozen_string_literal: true

# Base class for AI assistant implementations (conversational brain)
class AiAssistant
  class Error < StandardError; end
  class NotImplementedError < Error; end

  def initialize(config = {})
    @config = config
  end

  # The assistant's display name
  def name
    raise NotImplementedError, "#{self.class} must implement #name"
  end

  # System instructions for the assistant
  def instructions
    raise NotImplementedError, "#{self.class} must implement #instructions"
  end

  # Send a message, get a response
  def chat(message)
    raise NotImplementedError, "#{self.class} must implement #chat"
  end

  # Send a delegation request within the current session
  def sessions_send(intent:, request:)
    raise NotImplementedError, "#{self.class} must implement #sessions_send"
  end
end
