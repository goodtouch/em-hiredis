module EventMachine::Hiredis
  class Client
    PUBSUB_MESSAGES = %w{message pmessage}.freeze

    include EventMachine::Hiredis::EventEmitter
    include EM::Deferrable

    def self.connect(host = 'localhost', port = 6379)
      new(host, port)
    end

    def initialize(host, port)
      @host, @port = host, port
      @subs, @psubs = [], []
      @defs = []
      @connection = EM.connect(host, port, Connection, host, port)

      @connection.on(:closed) do
        if @connected
          @defs.each { |d| d.fail("Redis disconnected") }
          @defs = []
          @deferred_status = nil
          @connected = false
          @reconnecting = true
          reconnect
        else
          EM.add_timer(1) { reconnect }
        end
      end

      @connection.on(:connected) do
        @connected = true
        select(@db) if @db
        @subs.each { |s| method_missing(:subscribe, s) }
        @psubs.each { |s| method_missing(:psubscribe, s) }
        succeed

        if @reconnecting
          @reconnecting = false
          emit(:reconnected)
        end
      end

      @connection.on(:message) do |reply|
        if RuntimeError === reply
          raise "Replies out of sync: #{reply.inspect}" if @defs.empty?
          deferred = @defs.shift
          deferred.fail(reply) if deferred
        else
          if reply && PUBSUB_MESSAGES.include?(reply[0]) # reply can be nil
            kind, subscription, d1, d2 = *reply

            case kind.to_sym
            when :message
              emit(:message, subscription, d1)
            when :pmessage
              emit(:pmessage, subscription, d1, d2)
            end
          else
            if @defs.empty?
              if @monitor_callback
                @monitor_callback.call(reply)
              else
                raise "Replies out of sync: #{reply.inspect}"
              end
            else
              deferred = @defs.shift
              deferred.succeed(reply) if deferred
            end
          end
        end
      end

      @connected = false
      @reconnecting = false
    end

    # Indicates that commands have been sent to redis but a reply has not yet
    # been received
    #
    # This can be useful for example to avoid stopping the
    # eventmachine reactor while there are outstanding commands
    #
    def pending_commands?
      @connected && @defs.size > 0
    end

    def subscribe(channel)
      @subs << channel
      method_missing(:subscribe, channel)
    end

    def unsubscribe(channel)
      @subs.delete(channel)
      method_missing(:unsubscribe, channel)
    end

    def psubscribe(channel)
      @psubs << channel
      method_missing(:psubscribe, channel)
    end

    def punsubscribe(channel)
      @psubs.delete(channel)
      method_missing(:punsubscribe, channel)
    end

    def select(db)
      @db = db
      method_missing(:select, db)
    end

    def monitor(&blk)
      @monitor_callback = blk
      method_missing(:monitor, &blk)
    end

    private

    def method_missing(sym, *args)
      deferred = EM::DefaultDeferrable.new
      # Shortcut for defining the callback case with just a block
      deferred.callback { |result| yield(result) } if block_given?

      if @connected
        @connection.send_command(sym, *args)
        @defs.push(deferred)
      else
        callback do
          @connection.send_command(sym, *args)
          @defs.push(deferred)
        end
      end

      deferred
    end

    def reconnect
      EventMachine::Hiredis.logger.debug("Trying to reconnect to Redis")
      @connection.reconnect @host, @port
    end
  end
end
