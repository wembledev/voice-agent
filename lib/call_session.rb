# frozen_string_literal: true

require_relative 'config'
require 'fileutils'

# Orchestrates a voice call: connects the voice agent, dials via SIP,
# bridges audio, and manages the call lifecycle including graceful
# shutdown with goodbye sequences.
#
# All components are injected — the instance has no knowledge of specific
# implementations (Baresip, Grok, OpenClaw, etc.).
#
# Use .build to construct from config, or .new for manual injection:
#
#   session = CallSession.build(number: '5550100', agent: 'ara', verbose: true)
#   session.on(:output) { |msg| puts msg }
#   session.on(:log)    { |msg| $stderr.puts msg }
#   trap('INT') { session.hangup }
#   session.start
#
class CallSession
  class Error < StandardError; end

  SOCKET_PATH = '/tmp/ausock.sock'
  LOCK_FILE   = File.join(File.expand_path('../..', __FILE__), 'tmp', 'call.pid')

  # Plain SIP client from config — for status/hangup/calls commands.
  def self.sip_client
    kind = Config.fetch(:sip, :client)
    case kind
    when 'baresip'
      require_relative 'sip_client/baresip'
      SipClient::Baresip.new(
        sip_username: Config.fetch(:sip, :username),
        sip_password: Config.fetch(:sip, :password),
        sip_server:   Config.fetch(:sip, :server),
        module_path:  Config.fetch(:sip, :module_path),
        ctrl_port:    Config.fetch(:sip, :ctrl_port)
      )
    else
      raise "Unknown sip.client=#{kind}"
    end
  end

  # Build a CallSession from config/default.yml
  def self.build(number:, agent: nil, verbose: false, transcript_path: nil, instructions: nil)
    profile   = Config.agent(agent)
    if instructions
      # Override personality while preserving agent identity. The voice
      # parameter already keeps the synthesis voice, but Grok also needs
      # the agent name in the instructions text to stay in character.
      profile = profile.merge('personality' => "Your name is #{profile['name']}. #{instructions}")
    end
    client    = build_client
    voice     = build_agent(profile, verbose: verbose)
    bridge    = build_bridge(voice, verbose: verbose)
    assistant = build_assistant(verbose: verbose)
    triggers  = build_triggers

    new(
      number: number, client: client, agent: voice, bridge: bridge,
      assistant: assistant, triggers: triggers, verbose: verbose,
      transcript_path: transcript_path
    )
  end

  def initialize(number:, client:, agent:, bridge:, assistant: nil, triggers: nil,
                 verbose: false, transcript_path: nil)
    @number = number
    @client = client
    @agent = agent
    @bridge = bridge
    @assistant = assistant
    @triggers = triggers
    @verbose = verbose
    @transcript_path = transcript_path
    @transcript_io = nil
    @start_time = Time.now
    @hanging_up = false
    @goodbye_pending = nil           # :keyword or :silence once goodbye sequence starts
    @silence_check_pending = false   # true after "Are you still there?" prompt
    @event_callbacks = Hash.new { |h, k| h[k] = [] }
    @done = Queue.new                # signaled when call should end
    @call_state = { last_response_at: nil, is_speaking: false }
    @threads = []                    # tracked background threads for cleanup
  end

  # Register an event callback.
  # Events: :output, :log
  def on(event, &block)
    @event_callbacks[event] << block
    self
  end

  # Start the call session. Blocks until the call ends.
  def start
    acquire_lock!
    @start_time = Time.now
    open_transcript
    wire_triggers
    connect_agent
    dial
  end

  # Initiate graceful hangup. Safe to call from signal handlers or any thread.
  def hangup
    hangup_sequence
  end

  private

  # --- Event emission ---

  def emit(event, msg = nil)
    @event_callbacks[event].each { |cb| cb.call(msg) }
  end

  def log(msg)
    return unless @verbose
    elapsed = Time.now - @start_time
    emit(:log, format("[%7.3f] %s", elapsed, msg))
  end

  # --- Transcript recording ---

  def open_transcript
    return unless @transcript_path

    dir = File.dirname(@transcript_path)
    FileUtils.mkdir_p(dir) unless File.directory?(dir)
    @transcript_io = File.open(@transcript_path, 'a')
    @transcript_io.sync = true

    @transcript_io.puts "Call Transcript — #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    @transcript_io.puts "Number: #{@number}"
    @transcript_io.puts "=" * 40
    @transcript_io.puts
  end

  def transcript(role, text)
    return unless @transcript_io

    elapsed = Time.now - @start_time
    mins = (elapsed / 60).to_i
    secs = elapsed % 60
    stamp = format("%02d:%04.1f", mins, secs)

    case role
    when :caller
      @transcript_io.puts "[#{stamp}] Caller: #{text}"
    when :agent
      @transcript_io.puts "[#{stamp}] Agent: #{text}"
    when :system
      @transcript_io.puts "[#{stamp}] --- #{text} ---"
    end
  end

  def close_transcript
    return unless @transcript_io

    elapsed = Time.now - @start_time
    @transcript_io.puts
    @transcript_io.puts "[#{format('%02d:%04.1f', (elapsed / 60).to_i, elapsed % 60)}] --- Call ended (duration: #{elapsed.round(1)}s) ---"
    @transcript_io.close
    @transcript_io = nil
  end

  # --- Trigger wiring ---

  def wire_triggers
    return unless @triggers

    @triggers.on(:hangup) { |ctx| handle_hangup_trigger(ctx) }
    @triggers.on(:delegate) { |_ctx, payload| handle_delegate(payload) } if @assistant
  end

  def handle_hangup_trigger(ctx)
    return if @hanging_up || @goodbye_pending

    reason = ctx[:transcript] ? :keyword : :silence

    if reason == :silence && !@silence_check_pending
      # Phase 1: Ask if the caller is still there
      @silence_check_pending = true
      log "silence detected — prompting 'are you still there?'"
      @agent.prompt_response(
        "The caller has been quiet for a while. " \
        "Ask if they're still there, something brief like: 'Hey, are you still there?'"
      )
      # Reset silence trigger so it can fire again for phase 2
      @call_state[:last_response_at] = nil
      @triggers&.reset!

      # Safety: if still silent after 10s, go straight to goodbye
      spawn_thread do
        sleep 10
        if @silence_check_pending && !@hanging_up && !@goodbye_pending
          log "no response after 'are you still there?' — proceeding to goodbye"
          begin_goodbye(:silence)
        end
      end
      return
    end

    # Phase 2 (silence after check) or keyword trigger: goodbye
    begin_goodbye(reason)
  end

  def begin_goodbye(reason)
    return if @hanging_up || @goodbye_pending

    log "hangup triggered (#{reason})"
    @goodbye_pending = reason

    if reason == :silence
      @agent.send_text(
        "The caller has gone quiet. Wrap up with a brief goodbye, " \
        "something like: 'Looks like you stepped away. Call back anytime. Goodbye!'"
      )
    end
    # For :keyword, the agent already heard the farewell through audio
    # and will respond with a natural goodbye — just wait for it.

    # Safety timeout in case the agent never responds
    spawn_thread do
      sleep 8
      if @goodbye_pending
        log "goodbye safety timeout — forcing hangup"
        hangup_sequence
      end
    end
  end

  def handle_delegate(payload)
    intent  = payload&.dig('intent') || 'unknown'
    request = payload&.dig('request') || ''
    call_id = @triggers.find('delegation')&.call_id

    log "delegate: trigger fired — intent=#{intent} request=#{request.inspect} call_id=#{call_id.inspect}"
    emit(:output, "\nDelegating: [#{intent}] #{request}")
    transcript(:system, "Delegating: [#{intent}] #{request}")

    unless call_id
      log "delegate: WARNING no call_id from DelegationTrigger — voice agent won't get tool result"
    end

    spawn_thread do
      begin
        log "delegate: sending to assistant (#{@assistant.name})"
        reply = @assistant.sessions_send(intent: intent, request: request)
        log "delegate: assistant replied (#{reply.to_s.bytesize}B): #{reply.to_s[0, 200].inspect}"
        transcript(:system, "Delegation result: #{reply.to_s[0, 500]}")

        if call_id
          log "delegate: sending tool result to voice agent — call_id=#{call_id}"
          @agent.send_tool_result(call_id, reply)
          log "delegate: tool result sent — waiting for voice agent to speak response"
        else
          log "delegate: skipping send_tool_result (no call_id)"
        end
      rescue => e
        emit(:output, "\nDelegation error: #{e.message}")
        log "delegate: ERROR #{e.class}: #{e.message}"
        log "delegate: #{e.backtrace&.first(3)&.join("\n         ")}"
        if call_id
          log "delegate: sending fallback error tool result"
          @agent.send_tool_result(call_id, "Sorry, I couldn't process that request.")
        end
      end
    end
  end

  # --- Agent connection ---

  def connect_agent
    emit(:output, "Connecting voice agent...")

    # Lambdas below capture `self` (this CallSession) at creation time.
    # They execute on the agent's event thread but self and @ivars resolve
    # correctly — Ruby instance variables live on the object, not the thread.
    @agent.connect(
      on_ready: -> {
        emit(:output, "Voice agent ready")
        log "agent connected"
      },
      on_session: ->(event) {
        if @verbose
          type = event['type']
          log "event: #{type}"
        end
      },
      on_audio: ->(data) {
        @call_state[:is_speaking] = true
        log "audio out: +#{data.bytesize}B  total=#{@bridge.bytes_out}B"
        @bridge.enqueue(data)
      },
      on_transcript: ->(text) {
        emit(:output, "\nAgent: #{text}")
        transcript(:agent, text)
        @triggers&.check(transcript: text, role: :assistant)
      },
      on_text: ->(delta) {
        log "text delta: #{delta.inspect}"
      },
      on_input_transcript: ->(text) {
        emit(:output, "\nCaller: #{text}")
        transcript(:caller, text)
        @triggers&.check(transcript: text, role: :user)
      },
      on_tool_call: ->(name, arguments, call_id) {
        log "tool call: #{name}(#{arguments})"
        transcript(:system, "Tool: #{name}(#{arguments})")
        @triggers&.check(tool_name: name, tool_arguments: arguments, tool_call_id: call_id)
      },
      on_speech_started: -> {
        log "VAD: speech started"
        if @silence_check_pending
          log "user spoke — cancelling silence check"
          @silence_check_pending = false
        end
        if @goodbye_pending
          log "user spoke — cancelling goodbye"
          @goodbye_pending = nil
          @triggers&.reset!  # re-arm so triggers can fire again later
        end
      },
      on_speech_stopped: -> {
        log "VAD: speech stopped"
      },
      on_response_done: ->(event) {
        @call_state[:is_speaking] = false
        if @verbose
          usage_info = event.dig('response', 'usage')
          log "response done  usage=#{usage_info.inspect}" if usage_info
        end

        # Delay last_response_at by estimated audio drain time so the
        # silence timer doesn't start while the caller is still hearing
        # the agent speak. Each queued chunk is ~160 bytes PCMU = 20 ms.
        queued_secs = @bridge.write_queue_size * 0.02
        spawn_thread do
          sleep queued_secs if queued_secs > 0
          @call_state[:last_response_at] = Time.now
          log "last_response_at set (after #{queued_secs.round(1)}s drain)"
        end

        # If we're waiting for the agent's goodbye, drain audio then hang up
        if @goodbye_pending
          log "goodbye response done — draining audio"
          drain_and_hangup
        end
      },
      on_error: ->(e) {
        emit(:output, "\nVoice agent error: #{e}")
        log "error: #{e.inspect}"
      },
      on_close: -> {
        log "agent disconnected"
      }
    )
  end

  # --- Dial and run ---

  def dial
    emit(:output, "Calling #{@number}...")
    log "dialing #{@number}"
    active = @client.call(@number)

    if active.any?
      call = active.first
      emit(:output, "Connected: #{call[:state]} #{call[:uri]}")
      log "call established: #{call.inspect}"
      transcript(:system, "Call connected")

      @bridge.start
      log "audio bridge started"
      emit(:output, "Audio bridge active -- Ctrl-C to hang up")

      start_silence_thread
      start_stats_thread

      # Block until hangup signals completion
      @done.pop
    else
      emit(:output, "Call may have failed")
      log "no active calls after dial"
      @agent.disconnect
    end
  end

  def start_silence_thread
    return unless @triggers
    spawn_thread do
      loop do
        sleep 2
        break if @hanging_up
        @triggers.check(@call_state)
      rescue => e
        break
      end
    end
  end

  def start_stats_thread
    return unless @verbose
    spawn_thread do
      loop do
        sleep 5
        break if @hanging_up
        log "stats: in=#{@bridge.bytes_in}B (#{(@bridge.bytes_in / 8000.0).round(1)}s)  out=#{@bridge.bytes_out}B (#{(@bridge.bytes_out / 8000.0).round(1)}s)  queue=#{@bridge.write_queue_size}"
      rescue => e
        break
      end
    end
  end

  # --- Thread management ---

  def spawn_thread(&block)
    t = Thread.new(&block)
    @threads << t
    t
  end

  # --- Shutdown ---

  def hangup_sequence
    return if @hanging_up
    @hanging_up = true
    @goodbye_pending = nil
    @silence_check_pending = false
    release_lock
    emit(:output, "\nHanging up...")
    log "hangup: stopping bridge"
    @bridge&.stop
    log "hangup: disconnecting agent"
    @agent&.disconnect
    log "hangup: sending SIP hangup"
    @client&.hangup
    @client.shutdown if @client.respond_to?(:shutdown)
    log_final_stats
    close_transcript
    # Clean up any lingering threads
    @threads.each { |t| t.join(1) unless t == Thread.current }
    @threads.each { |t| t.kill if t.alive? && t != Thread.current }
    @threads.clear
    @done.push(:hangup)  # unblock dial
  end

  def drain_and_hangup
    spawn_thread do
      while @bridge.write_queue_size > 0
        break unless @goodbye_pending
        sleep 0.1
      end
      if @goodbye_pending
        sleep 0.5  # let final audio play through
        log "goodbye audio drained"
        hangup_sequence
      else
        log "goodbye cancelled during drain"
      end
    end
  end

  def log_final_stats
    return unless @verbose
    emit(:log, format(
      "\n[%7.3f] final: in=%dB (%.1fs) out=%dB (%.1fs)",
      Time.now - @start_time,
      @bridge&.bytes_in.to_i, @bridge&.bytes_in.to_i / 8000.0,
      @bridge&.bytes_out.to_i, @bridge&.bytes_out.to_i / 8000.0
    ))
  end

  # --- Lock file (prevents multiple simultaneous calls) ---

  def acquire_lock!
    if File.exist?(LOCK_FILE)
      existing_pid = File.read(LOCK_FILE).strip.to_i
      if existing_pid > 0 && process_alive?(existing_pid)
        raise Error, "Another call is already running (PID #{existing_pid}). Hang up first: bin/call hangup"
      end
      # Stale lock from a crashed session — safe to remove
    end
    FileUtils.mkdir_p(File.dirname(LOCK_FILE))
    File.write(LOCK_FILE, Process.pid.to_s)
  end

  def release_lock
    File.delete(LOCK_FILE) if File.exist?(LOCK_FILE)
  rescue Errno::ENOENT
    # Already removed — fine
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # --- Config-driven component builders (class methods) ---

  def self.build_client
    kind = Config.fetch(:sip, :client)
    case kind
    when 'baresip'
      require_relative 'sip_client/baresip'
      SipClient::Baresip.new(
        sip_username: Config.fetch(:sip, :username),
        sip_password: Config.fetch(:sip, :password),
        sip_server:   Config.fetch(:sip, :server),
        module_path:  Config.fetch(:sip, :module_path),
        ctrl_port:    Config.fetch(:sip, :ctrl_port),
        voice_socket: SOCKET_PATH
      )
    else
      raise "Unknown sip.client=#{kind}"
    end
  end

  def self.build_agent(agent_profile, verbose: false)
    kind = Config.fetch(:voice_agent, :provider)
    case kind
    when 'grok'
      require_relative 'voice_agent/grok'
      VoiceAgent::Grok.new(
        voice:        agent_profile['voice'],
        agent_name:   agent_profile['name'],
        instructions: agent_profile['personality'],
        tools:        [VoiceAgent::Grok::CLASSIFY_INTENT_TOOL],
        verbose:      verbose
      )
    when 'local'
      require_relative 'voice_agent/local'
      VoiceAgent::Local.new(
        voice:        agent_profile['voice'],
        agent_name:   agent_profile['name'],
        instructions: agent_profile['personality'],
        trump:        agent_profile['trump'] || false,
        tts_instruct: agent_profile['tts_instruct'],
        ref_audio:    agent_profile['ref_audio'],
        ref_text:     agent_profile['ref_text'],
        verbose:      verbose
      )
    else
      raise "Unknown voice_agent.provider=#{kind}"
    end
  end

  def self.build_bridge(agent, verbose: false)
    require_relative 'audio_bridge'
    AudioBridge.new(agent, socket_path: SOCKET_PATH, verbose: verbose)
  end

  def self.build_assistant(verbose: false)
    kind = Config.fetch(:ai_assistant, :provider)
    case kind
    when 'openclaw'
      require_relative 'ai_assistant/openclaw'
      assistant = AiAssistant::OpenClaw.new(verbose: verbose)
      assistant.configured? ? assistant : nil
    else
      nil
    end
  rescue => e
    nil
  end

  def self.build_triggers
    require_relative 'triggers'
    triggers = TriggerManager.new
    triggers.add(KeywordTrigger.new(action: :hangup))
    triggers.add(SilenceTrigger.new(timeout: 30, action: :hangup))
    triggers.add(DelegationTrigger.new)
    triggers
  end

  private_class_method :build_client, :build_agent, :build_bridge,
                       :build_assistant, :build_triggers
end
