# frozen_string_literal: true

require_relative '../voice_agent'
require 'json'
require 'net/http'
require 'uri'
require 'open3'

class VoiceAgent
  # Local voice pipeline: STT (Whisper) → LLM (Grok text) → TTS (Qwen3-TTS)
  #
  # Replaces the Grok Realtime API with fully local STT and TTS, using the
  # Grok text API for the LLM conversation layer. Audio is processed through
  # Python subprocesses that communicate via stdin/stdout.
  #
  # Callbacks match VoiceAgent::Grok's interface so CallSession works unchanged.
  class Local < VoiceAgent
    VENV_PYTHON = File.expand_path('../../../tts/.venv/bin/python', __FILE__)
    TTS_SCRIPT  = File.expand_path('../../../tts/tts_server.py', __FILE__)
    STT_SCRIPT  = File.expand_path('../../../tts/stt_server.py', __FILE__)

    # 4-byte sentinel written by Python after each utterance's audio.
    # Must match UTTERANCE_BOUNDARY in tts_server.py.
    BOUNDARY_SENTINEL = [0xDEADBEEF].pack('V').freeze  # "\xEF\xBE\xAD\xDE"

    def initialize(config = {})
      super
      @api_key      = config[:api_key] || ENV.fetch('XAI_API_KEY') { raise "XAI_API_KEY not set" }
      @voice        = config[:voice] || 'ryan'
      @agent_name   = config[:agent_name] || 'Assistant'
      @instructions = config[:instructions] || "You are #{@agent_name}, a helpful AI voice assistant. Be concise and conversational."
      @trump        = config[:trump] || false
      @tts_instruct = config[:tts_instruct]
      @ref_audio    = config[:ref_audio]
      @ref_text     = config[:ref_text]
      @verbose      = config[:verbose] || false

      @callbacks    = {}
      @connected    = false
      @conversation = []  # LLM message history
      @threads      = []
      @mutex        = Mutex.new
      @speaking     = false
      @interrupt    = false
      @interrupt_transcript = nil
      @awaiting_greeting = true  # suppress noise until caller actually speaks
      @audio_done   = Queue.new  # signaled when all audio for an utterance is delivered
      @utterance_queue = Queue.new  # serialized STT → LLM processing
      @cooldown_until  = 0.0       # monotonic time; ignore STT until this
    end

    def connect(**callbacks)
      @callbacks = callbacks

      start_tts
      start_stt

      # Wait for both subprocesses to report ready
      wait_for_ready

      @connected = true

      # Start the single utterance worker thread (serializes STT → LLM → TTS)
      @threads << Thread.new { utterance_worker }

      @callbacks[:on_ready]&.call
      self
    end

    # Receive PCMU audio from the caller (via AudioBridge).
    # Decode to S16LE, pipe to STT subprocess.
    def send_audio(data)
      return unless @connected && @stt_stdin

      # PCMU → S16LE (reuse AudioBridge codec)
      s16le = AudioBridge.pcmu_to_s16le(data)
      @stt_stdin.write(s16le)
    rescue IOError, Errno::EPIPE
      vlog "send_audio: STT pipe broken"
    end

    # Inject text directly (bypasses STT)
    def send_text(text)
      return unless @connected
      process_utterance(text)
    end

    # Send tool result back — for Local, just inject as assistant context
    def send_tool_result(call_id, output)
      vlog "send_tool_result: ignored (local pipeline)"
    end

    # Prompt the agent to say something specific
    def prompt_response(instructions)
      return unless @connected
      Thread.new { generate_response(instructions) }
    end

    def disconnect
      @connected = false
      @utterance_queue.close rescue nil
      cleanup_processes
    end

    def connected?
      @connected
    end

    private

    def vlog(msg)
      return unless @verbose
      $stderr.puts "[local] #{msg}"
    end

    # --- Subprocess management ---

    def start_tts
      cmd = [VENV_PYTHON, '-u', TTS_SCRIPT]  # -u forces unbuffered I/O
      cmd += ['--trump'] if @trump
      cmd += ['--voice', @voice] if @voice
      cmd += ['--instruct', @tts_instruct] if @tts_instruct
      cmd += ['--ref-audio', @ref_audio] if @ref_audio
      cmd += ['--ref-text', @ref_text] if @ref_text

      vlog "starting TTS: #{cmd.join(' ')}"
      @tts_stdin, @tts_stdout, @tts_stderr, @tts_wait = Open3.popen3(*cmd)

      # Set binary mode for audio I/O
      @tts_stdin.binmode
      @tts_stdout.binmode

      # Read TTS audio output → convert to PCMU → fire on_audio callback
      @threads << Thread.new { tts_audio_reader }
      # Read TTS status from stderr
      @threads << Thread.new { tts_status_reader }
    end

    def start_stt
      cmd = [VENV_PYTHON, '-u', STT_SCRIPT]  # -u forces unbuffered I/O
      vlog "starting STT: #{cmd.join(' ')}"
      @stt_stdin, @stt_stdout, @stt_stderr, @stt_wait = Open3.popen3(*cmd)

      # Read STT transcripts from stdout
      @threads << Thread.new { stt_output_reader }
      # Read STT status from stderr
      @threads << Thread.new { stt_status_reader }
    end

    def wait_for_ready
      deadline = Time.now + 120  # 2 minutes for model loading
      until @tts_ready && @stt_ready
        if Time.now > deadline
          raise Error, "Subprocess startup timed out (tts=#{@tts_ready}, stt=#{@stt_ready})"
        end
        sleep 0.5
      end
      vlog "both subprocesses ready"
    end

    def cleanup_processes
      [@tts_stdin, @stt_stdin].each { |io| io&.close rescue nil }
      [@tts_stdout, @stt_stdout, @tts_stderr, @stt_stderr].each { |io| io&.close rescue nil }
      [@tts_wait, @stt_wait].each { |thr| thr&.value rescue nil }
      @threads.each { |t| t.join(2) }
      @threads.each { |t| t.kill if t.alive? }
      @threads.clear
    end

    # --- TTS audio reader (stdout → PCMU → callback) ---
    #
    # Reads raw S16LE bytes from the TTS subprocess stdout. The Python side
    # pads each utterance to a 320-byte frame boundary and writes a 4-byte
    # sentinel (0xDEADBEEF) at the end. This reader:
    #
    # 1. Buffers incoming bytes
    # 2. Extracts complete 320-byte frames → converts to PCMU → on_audio
    # 3. Detects the sentinel → discards partial frames → signals audio_done
    #
    # This eliminates frame misalignment between utterances and ensures the
    # on_response_done callback fires only after all audio is delivered.

    def tts_audio_reader
      frame_bytes = AudioBridge::FRAME_BYTES  # 320 bytes S16LE
      sentinel = BOUNDARY_SENTINEL
      buffer = String.new(encoding: 'BINARY', capacity: 16384)
      frame_count = 0
      first_sentinel = true  # skip warmup flush sentinel

      loop do
        begin
          chunk = @tts_stdout.readpartial(16384)
        rescue EOFError
          vlog "TTS stdout EOF"
          break
        end

        break unless chunk && chunk.bytesize > 0
        buffer << chunk

        # Scan for boundary sentinel in the buffer
        while (sentinel_pos = buffer.index(sentinel))
          # Process all complete frames before the sentinel
          audio_portion = buffer.slice!(0, sentinel_pos)
          buffer.slice!(0, sentinel.bytesize)  # consume sentinel

          # Frame and deliver the audio portion
          offset = 0
          while offset + frame_bytes <= audio_portion.bytesize
            frame = audio_portion.byteslice(offset, frame_bytes)
            pcmu = AudioBridge.s16le_to_pcmu(frame)
            @callbacks[:on_audio]&.call(pcmu)
            frame_count += 1
            offset += frame_bytes
          end

          # Discard any leftover bytes (should be 0 since Python pads)
          leftover = audio_portion.bytesize - offset
          vlog "TTS boundary: #{frame_count} frames delivered (#{leftover}B discarded)" if leftover > 0

          # Signal that all audio for this utterance has been delivered.
          # Skip the first sentinel — it's the warmup flush from tts_server.py.
          if first_sentinel
            first_sentinel = false
            vlog "TTS warmup sentinel (skipped)"
          else
            @audio_done.push(:complete)
          end
          frame_count = 0
        end

        # Process complete frames from remaining buffer (between sentinels)
        while buffer.bytesize >= frame_bytes + sentinel.bytesize || buffer.bytesize >= frame_bytes
          # Don't consume bytes that might be the start of a sentinel
          # Only process if we have enough bytes to confirm it's not a sentinel
          break if buffer.bytesize < frame_bytes + sentinel.bytesize && buffer.include?(sentinel[0, [buffer.bytesize - frame_bytes, 1].max])

          frame = buffer.slice!(0, frame_bytes)
          pcmu = AudioBridge.s16le_to_pcmu(frame)
          @callbacks[:on_audio]&.call(pcmu)
          frame_count += 1
        end
      end

      vlog "TTS audio reader done"
    rescue IOError, Errno::EPIPE => e
      vlog "TTS audio reader stopped: #{e.class}: #{e.message}"
    end

    # TTS status reader — purely informational logging.
    # Lifecycle (@speaking, @cooldown_until, on_response_done) is managed by
    # stream_and_speak, which waits on @audio_done directly.
    def tts_status_reader
      @tts_ready = false
      while (line = @tts_stderr.gets)
        line = line.force_encoding('UTF-8').scrub.strip
        next if line.empty?

        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError
          vlog "TTS stderr: #{line}" if @verbose
          next
        end

        case msg['status']
        when 'ready'
          @tts_ready = true
          vlog "TTS ready"
        when 'generating'
          vlog "TTS generating"
        when 'audio_complete'
          vlog "TTS audio written: #{msg['bytes']}B"
        when 'done'
          vlog "TTS done: #{msg['audio_duration']}s in #{msg['gen_time']}s (#{msg['rtf']}x RT)"
        when 'error'
          vlog "TTS error: #{msg['message']}"
          @callbacks[:on_error]&.call(msg['message'])
        end
      end
    rescue IOError
      vlog "TTS status reader stopped"
    end

    # --- STT output reader (stdout → transcript → LLM → TTS) ---

    def stt_output_reader
      while (line = @stt_stdout.gets)
        line.strip!
        next if line.empty?

        msg = JSON.parse(line) rescue next

        case msg['type']
        when 'speech_started'
          @callbacks[:on_speech_started]&.call
        when 'speech_stopped'
          @callbacks[:on_speech_stopped]&.call
        when 'transcript'
          text = msg['text']

          # Wait for a real human greeting before starting the conversation.
          # Ring tones and connection noise produce short Whisper hallucinations
          # ("you", "the", etc.) — require >= 4 chars to count as a real greeting.
          if @awaiting_greeting
            if text.strip.length >= 4
              @awaiting_greeting = false
              vlog "STT greeting accepted: #{text.inspect}"
            else
              vlog "STT transcript (suppressed — awaiting greeting): #{text.inspect}"
              next
            end
          end

          # Echo suppression: discard transcripts while agent is speaking
          # or within cooldown window after speech ends (phone echo delay).
          # Exception: real speech (>= 10 chars, >= 2 words) during playback
          # triggers barge-in so the caller can interrupt the agent.
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @speaking || now < @cooldown_until
            if @speaking && text.strip.length >= 10 && text.split.size >= 2
              @interrupt_transcript = text
              @interrupt = true
              vlog "STT interrupt detected: #{text.inspect}"
            else
              vlog "STT transcript (suppressed — echo): #{text.inspect}"
            end
            next
          end

          vlog "STT transcript: #{text.inspect} (#{msg['latency']}s)"
          @callbacks[:on_input_transcript]&.call(text)
          @utterance_queue << text
        end
      end
    rescue IOError, ClosedQueueError
      vlog "STT output reader stopped"
    end

    # Single worker thread that processes utterances sequentially.
    # Prevents concurrent @conversation mutations and overlapping TTS generations.
    def utterance_worker
      while (text = @utterance_queue.pop)
        process_utterance(text)
      end
    rescue ClosedQueueError
      vlog "utterance worker stopped"
    end

    def stt_status_reader
      @stt_ready = false
      while (line = @stt_stderr.gets)
        line = line.force_encoding('UTF-8').scrub.strip
        next if line.empty?

        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError
          vlog "STT stderr: #{line}" if @verbose
          next
        end

        case msg['status']
        when 'ready'
          @stt_ready = true
          vlog "STT ready"
        when 'error'
          vlog "STT error: #{msg['message']}"
        end
      end
    rescue IOError
      vlog "STT status reader stopped"
    end

    # --- LLM (Grok text API) ---

    def process_utterance(user_text)
      return unless @connected

      @mutex.synchronize { @conversation << { role: 'user', content: user_text } }
      stream_and_speak(messages: @mutex.synchronize { @conversation.dup })
    rescue => e
      vlog "process_utterance error: #{e.class}: #{e.message}"
      @callbacks[:on_error]&.call(e.message)
      @speaking = false
    end

    def generate_response(instructions)
      messages = @mutex.synchronize do
        @conversation + [{ role: 'user', content: "[System: #{instructions}]" }]
      end
      stream_and_speak(messages: messages)
    rescue => e
      vlog "generate_response error: #{e.class}: #{e.message}"
      @speaking = false
    end

    # Stream LLM tokens, split into sentences, and send each to TTS with
    # sentence-level pacing: wait for the previous sentence's audio to finish
    # before sending the next. This creates natural ~1s pauses (TTS startup
    # latency) and enables barge-in — if STT detects real caller speech between
    # sentences, we stop generating and respond to the interrupt.
    def stream_and_speak(messages:)
      @speaking = true
      @interrupt = false
      @interrupt_transcript = nil

      full_response = String.new
      sentences_sent = 0
      sentences_completed = 0
      buffer = String.new
      interrupted = false

      catch(:interrupted) do
        stream_grok_text_api(messages: messages) do |token|
          buffer << token
          while (sentence = extract_sentence!(buffer))
            # Wait for previous sentence's audio before sending next
            if sentences_sent > sentences_completed
              @audio_done.pop(timeout: 30) rescue nil
              sentences_completed += 1
              if @interrupt
                interrupted = true
                throw :interrupted
              end
            end
            send_to_tts(sentence)
            sentences_sent += 1
            full_response << sentence
          end
        end

        # Wait for last streamed sentence before flushing remainder
        if sentences_sent > sentences_completed
          @audio_done.pop(timeout: 30) rescue nil
          sentences_completed += 1
          interrupted = @interrupt
        end

        # Flush remaining buffer
        unless interrupted || buffer.strip.empty?
          send_to_tts(buffer.strip)
          sentences_sent += 1
          full_response << buffer
        end

        # Wait for final sentence
        unless interrupted
          if sentences_sent > sentences_completed
            @audio_done.pop(timeout: 30) rescue nil
            sentences_completed += 1
            interrupted = @interrupt
          end
        end
      end # catch(:interrupted)

      if full_response.strip.empty? && !interrupted
        @speaking = false
        return nil
      end

      # Save partial or complete response to conversation
      unless full_response.strip.empty?
        @mutex.synchronize { @conversation << { role: 'assistant', content: full_response } }
        @callbacks[:on_transcript]&.call(full_response)
      end

      if interrupted
        # Drain any outstanding TTS sentinels
        remaining = sentences_sent - sentences_completed
        remaining.times { @audio_done.pop(timeout: 15) rescue break }

        @speaking = false
        @cooldown_until = 0.0  # Don't suppress the interrupt

        vlog "BARGE-IN: interrupted after #{sentences_completed} sentences, re-queuing: #{@interrupt_transcript.inspect}"
        @callbacks[:on_input_transcript]&.call(@interrupt_transcript)
        @utterance_queue << @interrupt_transcript
      else
        @speaking = false
        @cooldown_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5
        @callbacks[:on_response_done]&.call({
          'type' => 'response.done',
          'response' => { 'usage' => {} }
        })
      end

      full_response
    end

    # Extract the first complete sentence from buffer, mutating it in place.
    # A sentence boundary is .!? followed by whitespace. Must be >= 20 chars
    # to avoid splitting on abbreviations (Dr., Mr., U.S.) or tiny fragments.
    def extract_sentence!(buffer)
      pos = 0
      while (match = buffer.match(/[.!?]\s/, pos))
        end_pos = match.begin(0) + 1
        if end_pos >= 20
          sentence = buffer.slice!(0, end_pos)
          buffer.lstrip!
          return sentence
        end
        pos = end_pos
      end
      nil
    end

    def stream_grok_text_api(messages:)
      system_msg = { role: 'system', content: @instructions }
      payload = {
        model: 'grok-3-mini',
        messages: [system_msg] + messages.last(20),
        max_tokens: 256,
        temperature: 0.7,
        stream: true,
      }

      uri = URI('https://api.x.ai/v1/chat/completions')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.path)
      req['Authorization'] = "Bearer #{@api_key}"
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(payload)

      vlog "LLM request (streaming): #{messages.last(1).inspect[0, 200]}"
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      full_text = String.new
      line_buffer = String.new

      http.request(req) do |resp|
        unless resp.is_a?(Net::HTTPSuccess)
          body = resp.read_body
          vlog "LLM API error: #{resp.code} #{body[0, 200]}"
          return nil
        end

        resp.read_body do |chunk|
          line_buffer << chunk
          while (newline_pos = line_buffer.index("\n"))
            line = line_buffer.slice!(0, newline_pos + 1).strip
            next if line.empty?
            next unless line.start_with?('data: ')

            data = line[6..]
            next if data == '[DONE]'

            begin
              parsed = JSON.parse(data)
              delta = parsed.dig('choices', 0, 'delta', 'content')
              if delta
                full_text << delta
                yield delta
              end
            rescue JSON::ParserError
              next
            end
          end
        end
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      vlog "LLM response (#{elapsed.round(2)}s, streamed): #{full_text.inspect[0, 200]}"
      full_text.strip.empty? ? nil : full_text.strip
    rescue => e
      vlog "LLM API error: #{e.class}: #{e.message}"
      nil
    end

    # --- TTS request ---

    def send_to_tts(text)
      return unless @connected && @tts_stdin

      req = { text: text }
      @tts_stdin.write(JSON.generate(req) + "\n")
      @tts_stdin.flush
      vlog "sent to TTS: #{text[0, 100].inspect}"
    rescue IOError, Errno::EPIPE
      vlog "send_to_tts: TTS pipe broken"
    end
  end
end
