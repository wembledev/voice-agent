# frozen_string_literal: true

# Base class for SIP client implementations
class SipClient
  class Error < StandardError; end
  class NotImplementedError < Error; end
  
  def initialize(config = {})
    @config = config
  end
  
  # Make a call to a phone number
  # @param number [String] Phone number to call
  # @param opts [Hash] Additional options
  def call(number, **opts)
    raise NotImplementedError, "#{self.class} must implement #call"
  end
  
  # Check registration status
  def status
    raise NotImplementedError, "#{self.class} must implement #status"
  end
  
  # Hangup active call
  def hangup
    raise NotImplementedError, "#{self.class} must implement #hangup"
  end

  # List active calls
  def calls
    raise NotImplementedError, "#{self.class} must implement #calls"
  end
end
