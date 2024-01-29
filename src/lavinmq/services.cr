require "./server"
require "./http/http_server"

module LavinMQ
  class Services
    getter amqp_server : Server
    getter http_server : HTTP::Server

    private def initialize
      config = LavinMQ::Config.instance
      @amqp_server = Server.new(config.data_dir)
      @http_server = HTTP::Server.new(@amqp_server)
    end

    def self.instance
      @@instance ||= new
    end

    def stop
      @amqp_server.stop
    end

    def start
      @amqp_server.start
    end
  end
end
