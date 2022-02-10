# frozen_string_literal: true

module HealthCheck
  class RedisHealthCheck
    extend BaseHealthCheck

    class << self
      def check(resource)
        raise "Wrong configuration. Missing 'redis' gem" unless defined?(::Redis)

        client.ping == 'PONG' ? '' : "Redis.ping returned #{res.inspect} instead of PONG"
      rescue Exception => err
        create_error 'redis', err.message
      ensure
        client.close if client.connected?
      end

      def client(resource)
        @client ||= Redis.new(
          {
            url: resource,
            password: HealthCheck.redis_password
          }.reject { |k, v| v.nil? }
        )
      end
    end
  end
end
