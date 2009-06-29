module Orbited
  module Session
    class TCPConnectionResource
      PingTimeout   = 5
      PingInterval  = 10
      AsyncCallback = "async.callback".freeze
      

      attr_reader :peer, :host

      def initialize(key, request)
        Orbited.logger.debug "initializing #{self.pretty_inspect}"
        @key = key
        @request = request
        
        @comet_transport = nil
        @msg_queue = []
        @unacknowledge_queue = []
        @last_acknowledge_id = 0
        @packet_id = 0
        
        @ping_timer = nil
        @timeout_timer = nil
        @close_timer = nil
        
        @lost_triggered = false

        @open = false
        @closed = false
        @closing = false
        Orbited.logger.debug "Opening Proxy"
        @proxy = Orbited::Session::Proxy.new self

        reset_ping_timer
      end

      def lose_connection
        # TODO self.close ?
        close('lose_connection', true)
        nil
      end

      def connection_lost
        Orbited.logger.debug("connectionLost... already triggered? #{@lost_triggered}")
        unless @lost_triggered
          Orbited.logger.debug('do trigger');
          @lost_triggered = true
          @socket.connection_lost
        end
      end

      def handle_get(request, transport_name)
        @request = request
        transport = Transport.create(transport_name, self)
        transport.on_close do 
          Orbited.logger.info "Connection closed"
        end
        EM.next_tick { @request.env[AsyncCallback].call transport.render }
        AsyncResponse
      end

      def handle_post(request) 
        @request = request
        EM.next_tick { parse_data @request.body.read }
        AsyncResponse
      end
      
      def render
        Orbited.logger.debug("render request=#{request}");
        
        acknowledge
        
        encoding = request.headers['tcp-encoding']
        # TODO instead of .write/.finish just return OK?
        request.write('OK')
        request.finish
        reset_ping_timer
      end

      def parse_data(data)
        # TODO this method is filled with areas that really should be put
        #       inside try/except blocks. We don't want errors caused by
        #       malicious IO.
        Orbited.logger.debug('RECV ' + data)
        frames = []
        current_frame  = []
        while data.size > 0
          is_last = data[0,1] == '0'
          l, data = data[1, data.size].split(',', 2)
          l = l.to_i
          arg = data[0,l]
          data = data[l, data.size]
          current_frame << arg
          if is_last
            frames << current_frame
            current_frame = []
          end
          Orbited.logger.debug([data, frames, current_frame].inspect)
        end

        # TODO do we really need the id? maybe we should take it out
        #       of the protocol...
        #       -mcarter 7-29-08
        #       I think its a safenet for unintentinal bugs;  we should
        #       compare it with the last one we received, and error or
        #       ignore if its not what we expect.
        #       -- rgl
        frames.each do |args|
          Orbited.logger.debug("parse_data frame=#{args.inspect}")
          id = args[0]
          name = args[1]
          if name == 'close'
            if len(args) != 2
              # TODO kill the connection with error.
              pass
            end
            lose_connection
          elsif name == 'data'
            # TODO should there be a try/except around this block?
            #       we don't want app-level code to break and cause
            #       only some packets to be delivered.
            if args.size != 3
              # TODO kill the connection with error.
#              pass
            end
            data = Base64.decode64(args[2])
            Orbited.logger.debug "transport is-a FakeTCPTransport #{@socket.pretty_inspect}"
            @socket.data_received(data)
          elsif name == 'ping'
            if args.size != 2
              # TODO kill the connection with error.
#              pass
            end
            # TODO do we have to do anything? I don't think so...
            #       -mcarter 7-30-08
            Orbited.logger.debug('parse_data PING? PONG!');
          end
        end
      end

      # Called by the callback attached to the comet_transport
      def transport_closed(transport)
        @comet_transport = nil if transport == @comet_transport
      end

      # Called by transports.comet_transport.render
      def transport_opened(transport)
        reset_ping_timer
        if @comet_transport and transport != @comet_transport
          @comet_transport.close
          @comet_transport = nil
        end
        
        Orbited.logger.debug("opened transport #{transport.pretty_inspect}")
        @comet_transport = transport
#        transport.after(:close) { transport_closed transport }
        
        acknowledge
        resend_unacknowledge_queue
        send_msg_queue
        unless @open
          @open = true
          send TCPOption.new('pingTimeout', PingTimeout)
          send TCPOption.new('pingInterval', PingInterval)
          send TCPOpen
        end
        @comet_transport.flush
      end

      def reset_ping_timer
        cancel_timers
        @ping_timer = EM::Timer.new(PingInterval) { send_ping }
      end

      def send_ping
        @ping_timer = nil
        send(TCPPing)
        @timeout_timer = EM::Timer.new(PingTimeout) { timeout }
      end

      def timeout
        @timeout_timer = nil
        close("timeout", true)
      end

      def cancel_timers
        if @timeout_timer
          @timeout_timer.cancel
          @timeout_timer = nil
        end
        if @ping_timer
          @ping_timer.cancel
          @ping_timer = nil
        end
      end

      def hard_close
        @closed = true
        cancel_timers
        if @close_timer
          @close_timer.cancel
          @close_timer = nil
        end
        if @comet_transport
          @comet_transport.close
          @comet_transport = nil
        end
        connection_lost
#        @root.remove_conn
      end

      def inspect
        "#<#{self.class.name}:#{object_id}>"
      end

      def close(reason="", now=false)
        if @closed
          Orbited.logger.debug('close called - already closed')
          return
        end
        @closing = true
         
        Orbited.logger.debug("close reason=#{reason} #{pretty_inspect}")
        send(TCPClose.new(reason))
        if now
          hard_close
        elsif not(@closing)
          cancel_timers
          @close_timer = reactor.callLater(ping_interval, hard_close)
        end
      end

      def acknowledge
        return unless @request && @request.params['ack']
        acknowledge_id = @request.params['ack'].to_i 
        Orbited.logger.debug("acknowledge acknowledge_id=#{acknowledge_id}")
        acknowledge_id = [acknowledge_id, @packet_id].min
        if acknowledge_id <= @last_acknowledge_id
          (acknowledge_id - @last_acknowledge_id).times do
            data, packet_id = @unacknowledge_queue.pop
            close("close acknowledgeed", true) if data.is_a?(TCPClose)
          end
        end
        @last_acknowledge_id = acknowledge_id
      end

      def send_msg_queue
        while @msg_queue.any? and @comet_transport do
          send(@msg_queue.pop, false)
        end
      end

      def send(data, flush=true)
        if not(@comet_transport)
          @msg_queue << data
        else
          @packet_id += 1
          _send(data, @packet_id)
          @unacknowledge_queue << [data, @packet_id]
          if flush
            @comet_transport.flush
          end
        end
      end

      def _send(data, packet_id="")
        Orbited.logger.debug("_send data=#{data} packet_id=#{packet_id}")
        if data == TCPPing
          @comet_transport.send_packet('ping', packet_id.to_s)
        elsif data == TCPOpen
          @comet_transport.send_packet('open', packet_id.to_s)
        elsif data.is_a? TCPClose
          @comet_transport.send_packet('close', packet_id.to_s, data.reason)
        elsif data.is_a? TCPOption
          @comet_transport.send_packet('opt', packet_id.to_s, data.payload)
        else
          @comet_transport.send_packet('data', packet_id.to_s, Base64.b64encode(data))
        end
      end

      def resend_unacknowledge_queue
        return unless @unacknowledge_queue.any?

        @unacknowledge_queue.each{|atom| _send atom.first, atom.last }
        
        acknowledge_id = @last_acknowledge_id + @unacknowledge_queue.size
      end
    end
  end
end
