# frozen_string_literal: true

require 'socket'

# Bridges baresip audio (S16LE over a Unix socket) with a VoiceAgent
# (PCMU over WebSocket).
#
# The ausock baresip module exposes a single full-duplex Unix stream
# socket.  This class connects to it and runs two threads:
#
#   read thread  — reads S16LE from socket (caller audio),
#                  converts to PCMU, sends to voice agent
#   write thread — dequeues PCMU from voice agent,
#                  converts to S16LE, writes to socket
#
class AudioBridge
  SOCKET_PATH = '/tmp/ausock.sock'
  FRAME_SAMPLES = 160           # 20 ms at 8 kHz mono
  FRAME_BYTES   = FRAME_SAMPLES * 2  # 320 bytes of S16LE
  PCMU_BYTES    = FRAME_SAMPLES      # 160 bytes of G.711u
  WRITE_AHEAD   = 0.1                # seconds of audio to buffer ahead in the socket

  attr_reader :bytes_in, :bytes_out

  def initialize(voice_agent, socket_path: SOCKET_PATH, verbose: false)
    @voice_agent = voice_agent
    @socket_path = socket_path
    @write_queue = Thread::Queue.new
    @running = false
    @socket = nil
    @threads = []
    @bytes_in  = 0  # PCMU bytes read from socket (caller -> agent)
    @bytes_out = 0  # PCMU bytes written to socket (agent -> caller)
    @verbose = verbose
    @last_chunk_at = nil
  end

  def start
    @running = true
    connect_socket
    @threads << Thread.new { read_loop }
    @threads << Thread.new { write_loop }
  end

  def stop
    @running = false
    @write_queue.close rescue ClosedQueueError
    @socket&.close rescue IOError
    @threads.each { |t| t.join(2) }
    @threads.each { |t| t.kill if t.alive? }
    @threads.clear
  end

  # Called by the voice agent's on_audio callback to enqueue PCMU
  # audio destined for the caller.
  def enqueue(pcmu_data)
    return unless @running
    
    if @verbose
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      gap = @last_chunk_at ? ((now - @last_chunk_at) * 1000).round(1) : 0
      @last_chunk_at = now
      $stderr.puts "[bridge] enqueue: #{pcmu_data.bytesize}B  gap=#{gap}ms  queue_depth=#{@write_queue.size}"
    end
    
    @write_queue << pcmu_data
  end

  def running?
    @running
  end

  # Number of audio chunks waiting to be written to the socket.
  def write_queue_size
    @write_queue.closed? ? 0 : @write_queue.size
  end

  # --- G.711 u-law codec -------------------------------------------------

  ULAW_BIAS = 0x84   # 132
  ULAW_CLIP = 32635

  # Segment lookup: maps (biased_sample >> 7) to segment number 0-7
  ULAW_COMPRESS = [
    0,0,1,1,2,2,2,2,3,3,3,3,3,3,3,3,
    4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,
    5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
    5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
  ].freeze

  # Pre-computed decode table: ulaw byte → signed 16-bit linear
  ULAW_DECODE = Array.new(256) { |i|
    v = ~i & 0xFF
    sign     = v & 0x80
    exponent = (v >> 4) & 0x07
    mantissa = v & 0x0F
    sample   = ((mantissa << 3) + ULAW_BIAS) << exponent
    sample  -= ULAW_BIAS
    sign != 0 ? -sample : sample
  }.freeze

  def self.linear_to_ulaw(sample)
    sign = 0
    if sample < 0
      sign = 0x80
      sample = -sample
    end
    sample = ULAW_CLIP if sample > ULAW_CLIP
    sample += ULAW_BIAS

    seg = ULAW_COMPRESS[(sample >> 7) & 0xFF]
    ~(sign | (seg << 4) | ((sample >> (seg + 3)) & 0x0F)) & 0xFF
  end

  def self.ulaw_to_linear(byte)
    ULAW_DECODE[byte]
  end

  # Batch conversions used by the bridge threads
  def self.s16le_to_pcmu(data)
    data.unpack('s<*').map { |s| linear_to_ulaw(s) }.pack('C*')
  end

  def self.pcmu_to_s16le(data)
    data.bytes.map { |b| ulaw_to_linear(b) }.pack('s<*')
  end

  private

  def connect_socket
    5.times do
      @socket = UNIXSocket.new(@socket_path)
      return
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      sleep 0.5
    end
    raise "Could not connect to audio socket at #{@socket_path}"
  end

  # Read caller audio from socket (S16LE), convert to PCMU,
  # forward to the voice agent.
  def read_loop
    while @running
      data = @socket.read(FRAME_BYTES)
      break unless data && data.bytesize == FRAME_BYTES

      pcmu = self.class.s16le_to_pcmu(data)
      @bytes_in += pcmu.bytesize
      @voice_agent.send_audio(pcmu)
    end
  rescue IOError, Errno::ECONNRESET, Errno::EPIPE
    # socket closed
  end

  # Dequeue PCMU from the voice agent, convert to S16LE,
  # write to socket for the caller to hear.
  #
  # Grok sends audio in large bursts (4-16 KB) but the socket
  # consumer (ausock.c src_thread) expects steady 20 ms frames.
  # We chop each burst into FRAME_SAMPLES-sized pieces and write
  # up to WRITE_AHEAD seconds ahead of real-time.  The kernel
  # socket buffer absorbs the early data; the C side reads at its
  # steady 20 ms monotonic-clock cadence regardless.
  #
  # This write-ahead approach makes the pipeline robust to CPU
  # scheduling jitter (e.g. when run as a subprocess alongside a
  # CPU-heavy LLM).  Without it, any sleep() overshoot causes the
  # C side to read silence — producing choppy audio.
  def write_loop
    frame_duration = FRAME_SAMPLES / 8000.0  # 0.02 s
    next_frame_at = nil
    frame_count = 0

    while @running
      pcmu = @write_queue.pop
      break unless pcmu

      @bytes_out += pcmu.bytesize

      offset = 0
      while offset < pcmu.bytesize
        chunk = pcmu.byteslice(offset, PCMU_BYTES) || break
        offset += chunk.bytesize

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        next_frame_at ||= now

        # Sleep only if we're more than WRITE_AHEAD ahead of schedule.
        # This fills the socket buffer with ~5 frames (100 ms) of
        # reserve that the C side can consume during Ruby stalls.
        ahead = next_frame_at - now
        sleep_duration = 0
        if ahead > WRITE_AHEAD
          sleep_target = ahead - WRITE_AHEAD
          sleep_start = now
          sleep(sleep_target)
          sleep_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - sleep_start
          
          if @verbose && (sleep_duration - sleep_target).abs > 0.005  # >5ms jitter
            jitter_ms = ((sleep_duration - sleep_target) * 1000).round(1)
            $stderr.puts "[bridge] sleep jitter: target=#{(sleep_target*1000).round(1)}ms actual=#{(sleep_duration*1000).round(1)}ms (#{jitter_ms > 0 ? '+' : ''}#{jitter_ms}ms)"
          end
        end

        s16le = self.class.pcmu_to_s16le(chunk)
        @socket.write(s16le)
        
        frame_count += 1
        if @verbose && frame_count % 50 == 0  # log every 50 frames (1 second)
          drift = next_frame_at - now
          $stderr.puts "[bridge] write: frame #{frame_count}  drift=#{(drift*1000).round(1)}ms  queue=#{@write_queue.size}"
        end

        next_frame_at += frame_duration
        next_frame_at = now + frame_duration if next_frame_at < now
      end
    end
  rescue IOError, Errno::ECONNRESET, Errno::EPIPE, ClosedQueueError
    # socket closed or queue closed
  end
end
