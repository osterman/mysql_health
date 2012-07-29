#
# mysql_health - a service for monitoring MySQL and exposing its health through an HTTP interface
# Copyright (C) 2012 Erik Osterman <e@osterman.com>
# 
# This file is part of mysql_health.
# 
# mysql_health is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# mysql_health is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with mysql_health.  If not, see <http://www.gnu.org/licenses/>.
#
require 'dbi'
require 'mysql'
require 'json'
require 'rufus-scheduler'

module MysqlHealth
  class Health
    @master_status = nil
    @slave_status = nil
    @scheduler = nil
    @options = nil

    def initialize(options = {})
      @options = options

      @mutex = Mutex.new
      @scheduler = Rufus::Scheduler.start_new
      def @scheduler.handle_exception(job, e)
        MysqlHealth.log.error "job #{job.job_id} caught #{e.class} exception '#{e}' #{e.backtrace.join("\n")}"
      end

      if options[:master]
        master_status = {}
        master_status[:status] = 503
        master_status[:content] = "Health of master not yet determined\n"
        self.master_status=(master_status)
        @scheduler.every options[:interval], :allow_overlapping => options[:allow_overlapping], :first_in => options[:delay] do 
          check_master
        end
      else
        master_status = {}
        master_status[:status] = '501 Not Enabled'
        master_status[:content] = "Health of master not enabled\n"
        self.master_status=(master_status)
      end

      if options[:slave]
        slave_status = {}
        slave_status[:status] = '501 Not Enabled'
        slave_status[:content] = "Health of slave not yet determined\n"
        self.slave_status=(slave_status)
        @scheduler.every options[:interval], :allow_overlapping => options[:allow_overlapping], :first_in => options[:delay] do 
          check_slave
        end
      else
        slave_status = {}
        slave_status[:status] = '501 Not Enabled'
        slave_status[:content] = "Health of slave not enabled\n"
        self.slave_status=(slave_status)
      end
    end

    def master_status=(response)
      @mutex.synchronize do
        MysqlHealth.log.info("master status: #{response[:status]}")
        @master_status = response
      end
    end

    def master_status 
      master_status = nil
      @mutex.synchronize do
        master_status = @master_status
      end
      return master_status
    end

    def slave_status=(response)
      @mutex.synchronize do 
        MysqlHealth.log.info("slave status: #{response[:status]}")
        @slave_status = response
      end
    end
    
    def slave_status
      slave_status = nil
      @mutex.synchronize do
        slave_status = @slave_status
      end
      return slave_status
    end

    def read_only?(dbh)
      variables = dbh.select_all("SHOW VARIABLES WHERE Variable_name = 'read_only' AND Value = 'ON'")
      return (variables.length == 1)
    end

    def check_master
      MysqlHealth.log.debug("check_master")

      # connect to the MySQL server
      dbh = DBI.connect(@options[:dsn], @options[:username], @options[:password])

      response = {}
      response[:content_type] = 'text/plain'

      status = {}
      dbh.select_all('SHOW STATUS') do |row|
        status[row[0].downcase.to_sym] = row[1]
      end
      mysqladmin_status = "Uptime: %s  Threads: %s  Questions: %s  Slow queries: %s  Opens: %s  Flush tables: %s  Open tables: %s  Queries per second avg: %.3f\n" %
                [ status[:uptime], status[:threads_running], status[:questions], status[:slow_queries], status[:opened_tables], status[:flush_commands], status[:open_tables], status[:queries].to_i/status[:uptime].to_i]
      if status.length > 0
        if read_only?(dbh)
          response[:status] = '503 Service Read Only'
          response[:content] = mysqladmin_status
        else
          response[:status] = '200 OK'
          response[:content] = mysqladmin_status
        end
      else
        response[:status] = '503 Service Unavailable'
        response[:content] = mysqladmin_status
      end
      self.master_status=(response)
    end

    def check_slave
      MysqlHealth.log.debug("check_slave")

      # connect to the MySQL server
      dbh = DBI.connect(@options[:dsn], @options[:username], @options[:password])

      response = {}
      response[:content_type] = 'text/plain'

      show_slave_status = []
      status = {}
      dbh.execute('SHOW SLAVE STATUS') do |sth|
        sth.fetch_hash() do |row|
          row.each_pair do |k,v|
            status[k.downcase.to_sym] = v
            show_slave_status << "#{k}: #{v}"
          end
        end
      end

      if status.length > 0
        seconds_behind_master = status[:seconds_behind_master]

        # We return a "203 Non-Authoritative Information" when replication is shot. We don't want to reduce site performance, but still want to track that something is awry.
        if seconds_behind_master.eql?('NULL')
          response[:status] = '203 Slave Stopped'
          response[:content] = status.to_json
          response[:content_type] = 'application/json'
        elsif seconds_behind_master.to_i > 60*30
          response[:status] = '203 Slave Behind'
          response[:content] = status.to_json
          response[:content_type] = 'application/json'
        elsif read_only?(dbh)
          response[:status] = '200 OK ' + seconds_behind_master  + ' Seconds Behind Master'
          response[:content] = status.to_json
          response[:content_type] = 'application/json'
        else
          response[:status] = '503 Service Unavailable'
          response[:content] = status.to_json
          response[:content_type] = 'application/json'
        end
      else
        response[:status] = '503 Slave Not Configured'
        response[:content] = show_slave_status.join("\n")
      end
      self.slave_status=(response)
    end
  end
end
