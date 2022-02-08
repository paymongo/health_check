# Copyright (c) 2010-2013 Ian Heggie, released under the MIT license.
# See MIT-LICENSE for details.

module HealthCheck
  class Utils

    @@default_smtp_settings =
        {
            address:               "localhost",
            port:                  25,
            domain:                'localhost.localdomain',
            user_name:             nil,
            password:              nil,
            authentication:        nil,
            enable_starttls_auto:  true
        }

    cattr_accessor :default_smtp_settings

    # process an array containing a list of checks
    def self.process_checks(checks, called_from_middleware = false)
      errors = ''
      error_check = ""
      response = {}
      body = []
      checks.each do |check|
        case check
          when 'and', 'site'
            # do nothing
          when "database"
            HealthCheck::Utils.get_database_version
          when "email"
            error_check = HealthCheck::Utils.check_email
            errors << error_check
          when "emailconf"
            error_check = HealthCheck::Utils.check_email if HealthCheck::Utils.mailer_configured?
            errors << error_check
          when "migrations", "migration"
            error_check = ""
            if defined?(ActiveRecord::Migration) and ActiveRecord::Migration.respond_to?(:check_pending!)
              # Rails 4+
              begin
                ActiveRecord::Migration.check_pending!
              rescue ActiveRecord::PendingMigrationError => ex
                  error_check = ex.message
                  errors << ex.message
              end
            else
              database_version  = HealthCheck::Utils.get_database_version
              migration_version = HealthCheck::Utils.get_migration_version
              if database_version.to_i != migration_version.to_i
                message = "Current database version (#{database_version}) does not match latest migration (#{migration_version}). "
                error_check = message
                errors << message
              end
            end
          when 'cache'
            error_check = HealthCheck::Utils.check_cache
            errors << error_check
          when 'resque-redis-if-present'
            error_check = HealthCheck::ResqueHealthCheck.check if defined?(::Resque)
            errors << error_check
          when 'sidekiq-redis-if-present'
            error_check = HealthCheck::SidekiqHealthCheck.check if defined?(::Sidekiq)
            errors << error_check
          when 'redis-if-present'
            error_check = HealthCheck::RedisHealthCheck.check if defined?(::Redis)
            errors << error_check
          when 's3-if-present'
            error_check = HealthCheck::S3HealthCheck.check if defined?(::Aws)
            errors << error_check
          when 'elasticsearch-if-present'
            error_check = HealthCheck::ElasticsearchHealthCheck.check if defined?(::Elasticsearch)
            errors << error_check
          when 'resque-redis'
            error_check = HealthCheck::ResqueHealthCheck.check
            errors << error_check
          when 'sidekiq-redis'
            error_check = HealthCheck::SidekiqHealthCheck.check
            errors << error_check
          when 'redis'
            error_check = HealthCheck::RedisHealthCheck.check
            errors << error_check
          when 's3'
            error_check = HealthCheck::S3HealthCheck.check
            errors << error_check
          when 'elasticsearch'
            error_check = HealthCheck::ElasticsearchHealthCheck.check
            errors << error_check
          when 'rabbitmq'
            error_check = HealthCheck::RabbitMQHealthCheck.check
            errors << error_check
          when "standard"
            standard_error_check = HealthCheck::Utils.process_checks(HealthCheck.standard_checks, called_from_middleware)
          when "middleware"
            message = "Health check not called from middleware - probably not installed as middleware."
            error_check = message unless called_from_middleware
            errors << error_check
          when "custom"
            HealthCheck.custom_checks.each do |name, list|
              list.each do |custom_check|
                errors << custom_check.call(self)
              end
            end
          when "all", "full"
            full_error_check = HealthCheck::Utils.process_checks(HealthCheck.full_checks, called_from_middleware)
          else
            if HealthCheck.custom_checks.include? check
               HealthCheck.custom_checks[check].each do |custom_check|
                 errors << custom_check.call(self)
               end
            else
              return "invalid argument to health_test."
            end

        end
        if check == "all" || check == "full"
          body = full_error_check[:body]
          errors = full_error_check[:errors]
        elsif check == "standard"
          body = standard_error_check[:body]
          errors = standard_error_check[:errors]
        else
          body << {
            name: check,
            healthy: error_check == "",
            error: error_check
          }

          errors << '. ' unless errors == '' || errors.end_with?('. ')
        end
      end
      response[:errors] = errors.strip
      response[:body] = body
      binding.pry
      return response
      # return errors.strip
    # rescue => e
    #   return e.message
    end

    def self.db_migrate_path
      # Lazy initialisation so Rails.root will be defined
      @@db_migrate_path ||= File.join(::Rails.root, 'db', 'migrate')
    end

    def self.db_migrate_path=(value)
      @@db_migrate_path = value
    end

    def self.mailer_configured?
      defined?(ActionMailer::Base) && (ActionMailer::Base.delivery_method != :smtp || HealthCheck::Utils.default_smtp_settings != ActionMailer::Base.smtp_settings)
    end

    def self.get_database_version
      ActiveRecord::Migrator.current_version if defined?(ActiveRecord)
    end

    def self.get_migration_version(dir = self.db_migrate_path)
      latest_migration = nil
      Dir[File.join(dir, "[0-9]*_*.rb")].each do |f|
        l = f.scan(/0*([0-9]+)_[_.a-zA-Z0-9]*.rb/).first.first rescue -1
        latest_migration = l if !latest_migration || l.to_i > latest_migration.to_i
      end
      latest_migration
    end

    def self.check_email
      case ActionMailer::Base.delivery_method
        when :smtp
          HealthCheck::Utils.check_smtp(ActionMailer::Base.smtp_settings, HealthCheck.smtp_timeout)
        when :sendmail
          HealthCheck::Utils.check_sendmail(ActionMailer::Base.sendmail_settings)
        else
          ''
      end
    end

    def self.check_sendmail(settings)
      File.executable?(settings[:location]) ? '' : 'no sendmail executable found. '
    end

    def self.check_smtp(settings, timeout)
      status = ''
      begin
        if @skip_external_checks
          status = '250'
        else
          smtp = Net::SMTP.new(settings[:address], settings[:port])
          smtp.enable_starttls if settings[:enable_starttls_auto]
          smtp.open_timeout = timeout
          smtp.read_timeout = timeout
          smtp.start(settings[:domain], settings[:user_name], settings[:password], settings[:authentication]) do
            status = smtp.helo(settings[:domain]).status
          end
        end
      rescue Exception => ex
        status = ex.to_s
      end
      (status =~ /^250/) ? '' : "SMTP: #{status || 'unexpected error'}. "
    end

    def self.check_cache
      t = Time.now.to_i
      value = "ok #{t}"
      ret = ::Rails.cache.read('__health_check_cache_test__')
      if ret.to_s =~ /^ok (\d+)$/
        diff = ($1.to_i - t).abs
        return('Cache expiry is broken. ') if diff > 30
      elsif ret
        return 'Cache is returning garbage. '
      end
      if ::Rails.cache.write('__health_check_cache_test__', value, expires_in: 2.seconds)
        ret = ::Rails.cache.read('__health_check_cache_test__')
        if ret =~ /^ok (\d+)$/
          diff = ($1.to_i - t).abs
          (diff < 2 ? '' : 'Out of date cache or time is skewed. ')
        else
          'Unable to read from cache. '
        end
      else
        'Unable to write to cache. '
      end
    end

  end
end
