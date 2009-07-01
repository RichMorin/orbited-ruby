module Orbited
  module Session
    class TCPResource
      include Extlib::Hook
      include Headers
      
      def self.connections
        @connections ||= Orbited.config[:tcp_session_storage].new
      end
      
      def connections
        @connections ||= self.class.connections
      end
      
      def session_id
        $1 if @request and @request.path[/\/tcp\/([\w]{32})/]
      end
      
      def transport_name
        $1 if @request and @request.path[/\/tcp\/[\w]{32}\/([\w]+)/]
      end
    
      # TODO: integrate Rack::Mount
      def call(env)
        @request = Rack::Request.new env
        Orbited.logger.debug "handling rack env: #{env["REQUEST_METHOD"]} #{@request.path}"

        connection = connections[session_id] if session_id
        if connection 
          Orbited.logger.debug "existing connection #{connection.pretty_inspect}"
          if transport_name
            return connection.handle_get @request, transport_name
          elsif env["REQUEST_METHOD"] == "POST"
            return connection.handle_post @request
          end
        end
        
        return NotFound if session_id and not(connection)
        
        key = nil
        while not(key) or connections.has_key?(key) do key = TCPKey.generate(32) end

        # @request.client and @request.host should be address.IPv4Address classes
        connections[key] = TCPConnectionResource.new(self, key, @request)
        Orbited.logger.debug("created conn: \n#{connections[key].pretty_inspect}")
        merge_default_headers
        [200, headers, key]
      end
         
      def remove_connection(signature)
        connections.delete signature
      end

    end
  end
end
