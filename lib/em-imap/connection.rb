module EventMachine
  module IMAP
    CRLF = "\r\n"
    module Connection
      include EM::Deferrable
      DG.enhance!(self)

      include IMAP::CommandSender
      include IMAP::ResponseParser

      # Create a new connection to an IMAP server.
      #
      # @param host, The host name (warning DNS lookups are synchronous)
      # @param port, The port to connect to.
      # @param ssl=false, Whether or not to use TLS.
      #
      # @return Connection, a deferrable that will succeed when the server
      #                     has replied with OK or PREAUTH, or fail if the
      #                     connection could not be established, or the
      #                     first response was BYE.
      #
      def self.connect(host, port, ssl=false)
        EventMachine.connect(host, port, self).tap do |conn|
          conn.start_tls if ssl
        end
      end

      # Send the command, with the given arguments, to the IMAP server.
      #
      # @param cmd, the name of the command to send (a string)
      # @param *args, the arguments for the command, serialized
      #               by Net::IMAP. (FIXME)
      #
      # @return Command, a listener and deferrable that will receive_event
      #                  with the responses from the IMAP server, and which
      #                  will succeed with a tagged response from the
      #                  server, or fail with a tagged error response, or
      #                  an exception.
      #
      #                  NOTE: The responses it overhears may be intended
      #                  for other commands that are running in parallel.
      #
      # Exceptions thrown during serialization will be thrown to the user,
      # exceptions thrown while communicating to the socket will cause the
      # returned command to fail.
      #
      def send_command(cmd, *args)
        Command.new(next_tag!, cmd, args).tap do |command|
          add_to_listener_pool(command)
          listen_for_tagged_response(command)
          listen_for_bye_response(command)
          send_command_object(command)
        end
      end

      # Create a new listener for responses from the IMAP server.
      #
      # @param  &block, a block to which all responses will be passed.
      # @return Listener, an object with a .stop method that you can
      #         use to unregister this block.
      #
      #         You may also want to listen on the Listener's errback
      #         for when problems arise. The Listener's callbacks will
      #         be called after you call its stop method.
      #
      def add_response_handler(&block)
        Listener.new(&block).tap do |listener|
          listener.stopback{ listener.succeed }
          add_to_listener_pool(listener)
          listen_for_bye_response(listener)
        end
      end

      def post_init
        @listeners = Set.new
        super
        listen_for_greeting
      end

      # Listen for the first response from the server and succeed or fail
      # the connection deferrable.
      def listen_for_greeting
        hello_listener = add_response_handler do |response|
          hello_listener.stop
          if response.is_a?(Net::IMAP::UntaggedResponse)
            if response.name == "BYE"
              fail Net::IMAP::ByeResponseError.new(response.raw_data)
            else
              succeed response
            end
          else
            fail Net::IMAP::ResponseParseError.new(response.raw_data)
          end
        end.errback do |e|
          fail e
        end
      end

      # Called when the connection is closed.
      # TODO: Figure out how to send a useful error...
      def unbind
        fail_all EOFError.new("Connection to IMAP server was unbound"), true
      end

      def fail_all(error, closed=false)
        # NOTE: Take a shallow clone of the listeners here so that we get guaranteed
        # behaviour. We want to fail any listeners that may be added by the errbacks
        # of other listeners.
        @listeners.clone.each{ |listener| listener.fail error } while @listeners.size > 0
        close_connection unless closed
      end

      def add_to_listener_pool(listener)
        @listeners << listener.bothback{ @listeners.delete listener }
      end

      # receive_response is a higher-level receive_data provided by
      # EM::IMAP::ResponseParser. Each response is a Net::IMAP response
      # object. (FIXME)
      def receive_response(response)
        # NOTE: Take a shallow clone of the listeners so that if receiving an
        # event causes a new listener to be added, it won't receive this response!
        @listeners.clone.each{ |listener| listener.receive_event response }
      end

      # Await the response that marks the completion of this command,
      # and succeed or fail the command as appropriate.
      def listen_for_tagged_response(command)
        command.listen do |response|
          if response.is_a?(Net::IMAP::TaggedResponse) && response.tag == command.tag
            case response.name
            when "NO"
              command.fail Net::IMAP::NoResponseError.new(response.data.text)
            when "BAD"
              command.fail Net::IMAP::BadResponseError.new(response.data.text)
            else
              command.succeed response
            end
          end
        end
      end

      # If we receive a BYE response from the server, then we're not going
      # to hear any more, so we fail all our listeners.
      def listen_for_bye_response(listener)
        listener.listen do |response|
          if response.is_a?(Net::IMAP::UntaggedResponse) && response.name == "BYE"
            listener.fail Net::IMAP::ByeResponseError.new(response.raw_data)
          end
        end
      end

      # Provides a next_tag! method to generate unique tags
      # for an IMAP session.
      module TagSequence
        def post_init
          super
          # Copying Net::IMAP
          @tag_prefix = "RUBY"
          @tagno = 0
        end

        def next_tag!
          @tagno += 1
          "%s%04d" % [@tag_prefix, @tagno]
        end
      end

      # Intercepts send_data and receive_data and logs them to STDOUT,
      # this should be the last module included.
      module Debug
        def send_data(data)
          puts "C: #{data.inspect}"
          super
        end

        def receive_data(data)
          puts "S: #{data.inspect}"
          super
        end
      end
      include IMAP::Connection::TagSequence
      def self.debug!
        include IMAP::Connection::Debug
      end
    end
  end
end
