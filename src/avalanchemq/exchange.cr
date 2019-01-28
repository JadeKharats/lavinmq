require "logger"
require "./policy"
require "./stats"
require "./amqp"
require "./queue"

module AvalancheMQ
  abstract class Exchange
    include PolicyTarget
    include Stats

    getter name, durable, auto_delete, internal, arguments, bindings, policy, vhost, type,
      alternate_exchange

    @alternate_exchange : String?
    @log : Logger

    rate_stats(%w(publish_in publish_out))
    property publish_in_count, publish_out_count
    alias BindingKey = Tuple(String, Hash(String, AMQP::Field)?)
    alias Destination = Set(Queue | Exchange)

    def initialize(@vhost : VHost, @name : String, @durable = false,
                   @auto_delete = false, @internal = false,
                   @arguments = Hash(String, AMQP::Field).new)
      @bindings = Hash(BindingKey, Destination).new do |h, k|
        h[k] = Set(Queue | Exchange).new
      end
      @log = @vhost.log.dup
      @log.progname += " exchange=#{@name}"
      handle_arguments
    end

    def apply_policy(policy : Policy)
      handle_arguments
      policy.not_nil!.definition.each do |k, v|
        @log.debug { "Applying policy #{k}: #{v}" }
        case k
        when "alternate-exchange"
          @alternate_exchange = v.as_s?
        end
      end
      @policy = policy
    end

    def clear_policy
      handle_arguments
      @policy = nil
    end

    def handle_arguments
      @alternate_exchange = @arguments["x-alternate-exchange"]?.try &.to_s
    end

    def to_json(builder : JSON::Builder)
      {
        name: @name, type: type, durable: @durable, auto_delete: @auto_delete,
        internal: @internal, arguments: @arguments, vhost: @vhost.name,
        policy: @policy.try &.name, effective_policy_definition: @policy,
        message_stats: stats_details,
      }.to_json(builder)
    end

    def self.make(vhost, name, type, durable, auto_delete, internal, arguments)
      case type
      when "direct"
        DirectExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      when "fanout"
        FanoutExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      when "topic"
        TopicExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      when "headers"
        HeadersExchange.new(vhost, name, durable, auto_delete, internal, arguments)
      else raise "Cannot make exchange type #{type}"
      end
    end

    def match?(frame : AMQP::Frame)
      type == frame.exchange_type &&
        @durable == frame.durable &&
        @auto_delete == frame.auto_delete &&
        @internal == frame.internal &&
        @arguments == frame.arguments
    end

    def match?(type, durable, auto_delete, internal, arguments)
      self.type == type &&
        @durable == durable &&
        @auto_delete == auto_delete &&
        @internal == internal &&
        @arguments == arguments
    end

    def in_use?
      in_use = bindings.size > 0
      unless in_use
        destinations = vhost.exchanges.each_value.flat_map(&.bindings.each_value.flat_map(&.to_a))
        in_use = destinations.includes?(self)
      end
      in_use
    end

    def bindings_details
      @bindings.flat_map do |key, desinations|
        desinations.map { |destination| binding_details(key, destination) }
      end
    end

    def binding_details(key, destination)
      {
        source:           name,
        vhost:            vhost.name,
        destination:      destination.name,
        destination_type: destination.is_a?(Queue) ? "queue" : "exchange",
        routing_key:      key[0],
        arguments:        key[1],
      }
    end

    private def after_unbind
      if @auto_delete && @bindings.each_value.none? { |s| s.size > 0 }
        delete
      end
    end

    protected def delete
      @log.info { "Deleting exchange: #{@name}" }
      @vhost.apply AMQP::Frame::Exchange::Delete.new 0_u16, 0_u16, @name, false, false
    end

    abstract def type : String
    abstract def bind(destination : Queue | Exchange, routing_key : String,
                      headers : Hash(String, AMQP::Field)?)
    abstract def unbind(destination : Queue | Exchange, routing_key : String,
                        headers : Hash(String, AMQP::Field)?)
    abstract def matches(routing_key : String, headers : Hash(String, AMQP::Field)?) : Set(Queue | Exchange)
  end

  class DirectExchange < Exchange
    def type
      "direct"
    end

    def bind(destination, routing_key, headers = nil)
      @bindings[{routing_key, nil}] << destination
    end

    def unbind(destination, routing_key, headers = nil)
      @bindings[{routing_key, nil}].delete destination
      after_unbind
    end

    def matches(routing_key, headers = nil)
      @bindings[{routing_key, nil}]
    end
  end

  class FanoutExchange < Exchange
    def type
      "fanout"
    end

    def bind(destination, routing_key, headers = nil)
      @bindings[{routing_key, nil}] << destination
    end

    def unbind(destination, routing_key, headers = nil)
      @bindings[{routing_key, nil}].delete destination
      after_unbind
    end

    def matches(routing_key, headers = nil)
      @bindings.each_value.reduce { |acc, i| acc.concat(i) }
    end
  end

  class TopicExchange < Exchange
    def type
      "topic"
    end

    def bind(destination, routing_key, headers = nil)
      @bindings[{routing_key, nil}] << destination
    end

    def unbind(destination, routing_key, headers = nil)
      @bindings[{routing_key, nil}].delete destination
      after_unbind
    end

    def matches(routing_key, headers = nil)
      rk_parts = routing_key.split(".")
      s = Set(Queue | Exchange).new
      @bindings.each do |bt, q|
        ok = false
        bk_parts = bt[0].split(".") # rk
        bk_parts.each_with_index do |part, i|
          if i > rk_parts.size - 1
            ok = false
            break
          end
          if part == "#"
            ok = true
            break
          end
          if part == "*" || part == rk_parts[i]
            if bk_parts.size == i + 1 && rk_parts.size > i + 1
              ok = false
            else
              ok = true
            end
            next
          else
            ok = false
            break
          end
        end
        s.concat(q) if ok
      end
      s
    end
  end

  class HeadersExchange < Exchange
    def type
      "headers"
    end

    def bind(destination, routing_key, headers)
      args = headers ? @arguments.merge(headers) : @arguments
      @bindings[{routing_key, args}] << destination
    end

    def unbind(destination, routing_key, headers)
      args = headers ? @arguments.merge(headers) : @arguments
      @bindings[{routing_key, args}].delete destination
      after_unbind
    end

    def matches(routing_key, headers)
      matches = Set(Queue | Exchange).new
      return matches unless headers
      @bindings.each do |bt, queues|
        args = bt[1]
        next unless args
        case args["x-match"]
        when "any"
          if headers.any? { |k, v| k != "x-match" && args.has_key?(k) && args[k] == v }
            matches.concat(queues)
          end
        else
          if headers.all? { |k, v| args.has_key?(k) && args[k] == v }
            matches.concat(queues)
          end
        end
      end
      matches
    end
  end
end
