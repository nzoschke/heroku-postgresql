module Heroku::Command
  class Pg < BaseWithApp
    include PgUtils

    Help.group("heroku-postgresql") do |group|
      group.command "pg:info",   "show database status"
      group.command "pg:wait",   "wait for the database to come online"
      group.command "pg:attach", "use the heroku-postgresql database for the DATABASE_URL"
      group.command "pg:detach", "revert to using the shared Postgres database"
      group.command "pg:psql",   "open a psql shell to the database"
      group.command "pg:ingress", "allow new connections from this IP to the database for one minute"

      # legacy pgpipe methods
      group.command "pg:backups",             "list legacy backups"
      group.command "pg:backup_url [<name>]", "get download URL for a legacy backup"
    end

    def initialize(*args)
      super
      @config_vars =  heroku.config_vars(app)
      @heroku_postgresql_url = ENV["HEROKU_POSTGRESQL_URL"] ||
                               @config_vars["HEROKU_POSTGRESQL_URL"] ||
                               @config_vars["HEROKU_POSTGRESQL_RONIN_URL"] ||
                               @config_vars["HEROKU_POSTGRESQL_FUGU_URL"] ||
                               @config_vars["HEROKU_POSTGRESQL_NINJA_URL"] ||
                               @config_vars["HEROKU_POSTGRESQL_KAPPA_URL"]

      @database_url = ENV["DATABASE_URL"] || @config_vars["DATABASE_URL"]
      if !@heroku_postgresql_url
        abort("The addon is not installed for the app #{app}")
      end
      uri = URI.parse(@heroku_postgresql_url.gsub("_", "-"))
      @database_user =     uri.user
      @database_password = uri.password
      @database_host =     uri.host
      @database_name =     uri.path[1..-1]
    end

    def info
      database = heroku_postgresql_client.get_database
      display("=== #{app} heroku-postgresql database")

      display_info("State",
        "#{database[:state]} for " +
        "#{delta_format(Time.parse(database[:state_updated_at]))}")

      if database[:num_bytes] && database[:num_tables]
        display_info("Data size",
          "#{size_format(database[:num_bytes])} in " +
          "#{database[:num_tables]} table#{database[:num_tables] == 1 ? "" : "s"}")
      end

      if @heroku_postgresql_url && !(@heroku_postgresql_url =~ /NOT.READY/)
        display_info("URL", @heroku_postgresql_url)
      end

      if version = database[:postgresql_version]
        display_info("PG version", version)
      end

      display_info("Born", time_format(database[:created_at]))
    end

    def wait
      ticking do |ticks|
        database = heroku_postgresql_client.get_database
        state = database[:state]
        if state == "available"
          redisplay("The database is now ready", true)
          break
        elsif state == "deprovisioned"
          redisplay("The database has been destroyed", true)
          break
        elsif state == "failed"
          redisplay("The database encountered an error", true)
          break
        else
          redisplay("#{state.capitalize} database #{spinner(ticks)}", false)
        end
      end
    end

    def attach
      with_running_database do |database|
        if @database_url == @heroku_postgresql_url
          display("The database is already attached to app #{app}")
        else
          display("Attatching database to app #{app} ... ", false)
          res = heroku.add_config_vars(app, {"DATABASE_URL" => @heroku_postgresql_url})
          display("done")
        end
      end
    end

    def detach
      if @database_url.nil?
        display("A heroku-postgresql database is not attached to app #{app}")
      elsif @database_url != @heroku_postgresql_url
        display("Database attached to app #{app} is not a heroku-postgresql database")
      else
        display("Detatching database from app #{app} ... ", false)
        res = heroku.remove_config_var(app, "DATABASE_URL")
        display("done")
      end
    end

    def psql
      with_psql_binary do
        with_running_database do |database|
          display("Connecting to database for app #{app} ...")
          heroku_postgresql_client.ingress
          ENV["PGPASSWORD"] = @database_password
          cmd = "psql -U #{@database_user} -h #{@database_host} #{@database_name}"
          system(cmd)
        end
      end
    end

    def ingress
      with_running_database do |database|
        display("Opening access to the database.")
        heroku_postgresql_client.ingress
        display("The database will accept new incoming connections for the next 60s.")
        display("Connection info string: \"dbname=#{@database_name} host=#{@database_host} user=#{@database_user} password=#{@database_password}\"")
      end
    end

    def backup
      abort("This feature has been deprecated. Please see http://docs.heroku.com/pgbackups#legacy")
    end

    def backups
      display "This feature has been deprecated. Please see http://docs.heroku.com/pgbackups#legacy\n"
      backups = heroku_postgresql_client.get_backups
      valid_backups = backups.select { |b| !b[:error_at] }
      if backups.empty?
        display("App #{app} has no database backups")
      else
        name_width = backups.map { |b| b[:name].length }.max
        backups.sort_by { |b| b[:started_at] }.reverse.each do |b|
          state =
            if b[:finished_at]
              size_format(b[:size_compressed])
            elsif prog = b[:progress]
              "#{prog.last.first.capitalize}ing"
            else
              "Pending"
            end
          display(format("%-#{name_width}s  %s", b[:name], state))
        end
      end
    end

    def backup_url
      display "This feature has been deprecated. Please see http://docs.heroku.com/pgbackups#legacy\n"

      with_optionally_named_backup do |backup|
        display("URL for backup #{backup[:name]}:\n#{backup[:dump_url]}")
      end
    end

    protected

    def with_running_database
      database = heroku_postgresql_client.get_database
      if database[:state] == "available"
        yield database
      else
        display("The database is not running")
      end
    end

    def with_optionally_named_backup
      backup_name = args.first && args.first.strip
      backup = backup_name ? heroku_postgresql_client.get_backup(backup_name) :
                             heroku_postgresql_client.get_backup_recent
      if backup[:finished_at]
        yield(backup)
      elsif backup[:error_at]
        display("Backup #{backup[:name]} did not complete successfully")
      else
        display("Backup #{backup[:name]} has not yet completed")
      end
    end

    def restore_with(restore_param)
      restore = heroku_postgresql_client.create_restore(restore_param)
      restore_id = restore[:id]
      ticking do |ticks|
        restore = heroku_postgresql_client.get_restore(restore_id)
        display_progress(restore[:progress], ticks)
        if restore[:error_at]
          display("\nAn error occured while restoring the backup")
          display(restore[:log])
          break
        elsif restore[:finished_at]
          display("Restore complete")
          break
        end
      end
    end

    def with_psql_binary
      if !has_binary?("psql")
        display("Please install the 'psql' command line tool")
      else
        yield
      end
    end

    def with_download_binary
      if has_binary?("curl")
        yield(:curl)
      elsif has_binary?("wget")
        yield(:wget)
      else
        display("Please install either the 'curl' or 'wget' command line tools")
      end
    end

    def exec_download(from, to, binary)
      if binary == :curl
        system("curl -o \"#{to}\" \"#{from}\"")
      elsif binary == :wget
        system("wget -O \"#{to}\" --no-check-certificate \"#{from}\"")
      else
        display("Unrecognized binary #{binary}")
      end
    end

    def heroku_postgresql_client
      ::HerokuPostgresql::Client.new(
        @database_user, @database_password, @database_name)
    end

    def ticking
      ticks = 0
      loop do
        yield(ticks)
        ticks +=1
        sleep 1
      end
    end

    def display_progress_part(part, ticks)
      task, amount = part
      if amount == "start"
        redisplay(format("%-10s ... %s", task.capitalize, spinner(ticks)))
        @last_amount = 0
      elsif amount.is_a?(Fixnum)
        redisplay(format("%-10s ... %s  %s", task.capitalize, size_format(amount), spinner(ticks)))
        @last_amount = amount
      elsif amount == "finish"
        redisplay(format("%-10s ... %s, done", task.capitalize, size_format(@last_amount)), true)
      end
    end

    def display_progress(progress, ticks)
      progress ||= []
      new_progress = ((progress || []) - (@seen_progress || []))
      if !new_progress.empty?
        new_progress.each { |p| display_progress_part(p, ticks) }
      elsif !progress.empty? && progress.last[0] != "finish"
        display_progress_part(progress.last, ticks)
      end
      @seen_progress = progress
    end

    def delta_format(start, finish = Time.now)
      secs = (finish.to_i - start.to_i).abs
      mins = (secs/60).round
      hours = (mins / 60).round
      days = (hours / 24).round
      weeks = (days / 7).round
      months = (weeks / 4.3).round
      years = (months / 12).round
      if years > 0
        "#{years} yr"
      elsif months > 0
        "#{months} mo"
      elsif weeks > 0
        "#{weeks} wk"
      elsif days > 0
        "#{days}d"
      elsif hours > 0
        "#{hours}h"
      elsif mins > 0
        "#{mins}m"
      else
        "#{secs}s"
      end
    end

    KB = 1024
    MB = 1024 * KB
    GB = 1024 * MB

    def size_format(bytes)
      return "#{bytes}B" if bytes < KB
      return "#{(bytes / KB)}KB" if bytes < MB
      return format("%.1fMB", (bytes.to_f / MB)) if bytes < GB
      return format("%.2fGB", (bytes.to_f / GB))
    end

    def time_format(time)
      time = Time.parse(time) if time.is_a?(String)
      time.strftime("%Y-%m-%d %H:%M %Z")
    end

    def timestamp_name
      Time.now.strftime("%Y-%m-%d-%H:%M:%S")
    end

    def has_binary?(binary)
      `which #{binary}` != ""
    end
  end
end
