# RedMine - project management software
# Copyright (C) 2006-2007  Jean-Philippe Lang
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# 
# You should have received a copy of the MIT
# along with this program; if not, assume this file
# follows the MIT license.
#
# RT3 migration by James Rowe Copyright (C) 2010
#
# Author::    James Rowe  (mailto:james.s.rowe@google.com)
# Copyright:: Copyright (c) 2010
# License::   Distributes under the MIT license

# includes
require 'active_record' # db access
require 'iconv' # setting char sets

namespace :redmine do
  desc "Migrate from RT3 to Redmine"
  task :migrate_from_rt3  => :environment do
    
    # RTMigrate module will map RT objects to Redmine objects
    module RTMigrate
      
      # set up the mappings from RT -> redmine
      # RT does not have by default a tracker. all tickets in are
      # "categorized" by queue, status, and priority
      TICKET_MAP = []

      DEFAULT_STATUS = IssueStatus.default
      assigned_status = IssueStatus.find_by_position(2)
      resolved_status = IssueStatus.find_by_position(3)
      feedback_status = IssueStatus.find_by_position(4)
      closed_status = IssueStatus.find :first, :conditions => { :is_closed => true }
      STATUS_MAPPING = {'new' => DEFAULT_STATUS,
                        'reopened' => feedback_status,
                        'assigned' => assigned_status,
                        'closed' => closed_status
                        }

      priorities = IssuePriority.all
      DEFAULT_PRIORITY = priorities[0]
      PRIORITY_MAPPING = {'lowest' => priorities[0],
                          'low' => priorities[0],
                          'normal' => priorities[1],
                          'high' => priorities[2],
                          'highest' => priorities[3],
                          # ---
                          'trivial' => priorities[0],
                          'minor' => priorities[1],
                          'major' => priorities[2],
                          'critical' => priorities[3],
                          'blocker' => priorities[4]
                          }

      TRACKER_BUG = Tracker.find_by_position(1)
      TRACKER_FEATURE = Tracker.find_by_position(2)
      DEFAULT_TRACKER = TRACKER_BUG
      TRACKER_MAPPING = {'defect' => TRACKER_BUG,
                         'enhancement' => TRACKER_FEATURE,
                         'task' => TRACKER_FEATURE,
                         'patch' =>TRACKER_FEATURE
                         }

      roles = Role.find(:all, :conditions => {:builtin => 0}, :order => 'position ASC')
      manager_role = roles[0]
      developer_role = roles[1]
      DEFAULT_ROLE = roles.last
      ROLE_MAPPING = {'admin' => manager_role,
                      'developer' => developer_role
                      }
      
      
      # entry point for migrate script.
      def self.migrate
        establish_connection
        
        # are we converting users?
        # RT User = Redmine User
        RTUsers.count
        
        puts "migrate me"
      end
      
      # make sure we have connections
      def self.establish_connection
        constants.each do |const|
          klass = const_get(const)
          next unless klass.respond_to? 'establish_connection'
          klass.establish_connection connection_params
        end
      end
      
      # user is prompted for redmine project name to migrate RT tickets => Redmine issues
      def self.target_project_identifier(identifier)
        project = Project.find_by_identifier(identifier)
        if !project
          # create the target project
          puts "Creating new project"
          project = Project.new :name => identifier.humanize,
                                :description => ''
          project.identifier = identifier
          puts "Unable to create a project with identifier '#{identifier}'!" unless project.save
          # enable issues and wiki for the created project
          project.enabled_module_names = ['issue_tracking', 'wiki']
        else
          puts
          puts "This project already exists in your Redmine database."
          print "Are you sure you want to append data to this project ? [Y/n] "
          STDOUT.flush
          exit if STDIN.gets.match(/^n$/i)
        end
        project.trackers << TRACKER_BUG unless project.trackers.include?(TRACKER_BUG)
        project.trackers << TRACKER_FEATURE unless project.trackers.include?(TRACKER_FEATURE)
        @target_project = project.new_record? ? nil : project
        @target_project.reload
      end
      
      # what we need to connect to RT3
      def self.connection_params
        if %w(sqlite sqlite3).include?(rt_adapter)
          {:adapter => rt_adapter,
           :database => rt_db_path}
        else
          {:adapter => rt_adapter,
           :database => rt_db_name,
           :host => rt_db_host,
           :port => rt_db_port,
           :username => rt_db_username,
           :password => rt_db_password,
           :schema_search_path => rt_db_schema
          }
        end
      end
      
      # Following are get/set for user collected prompts
      def self.encoding(charset)
        @ic = Iconv.new('UTF-8', charset)
      rescue Iconv::InvalidEncoding
        puts "Invalid encoding!"
        return false
      end

      def self.set_rt_directory(path)
        @@rt_directory = path
        raise "This directory doesn't exist!" unless File.directory?(path)
        # RT stores attatchments in database
        # raise "#{rt_attachments_directory} doesn't exist!" unless File.directory?(rt_attachments_directory)
        @@rt_directory
      rescue Exception => e
        puts e
        return false
      end

      def self.rt_directory
        @@rt_directory
      end
      
      # queue to serve as source of tickets
      def self.set_rt_queue(queue)
        @@rt_queue = queue
      end
      
      def self.get_rt_queue
        return @@rt_queue
      end
      
      def self.rt_queue
        @@rt_queue
      end

      def self.set_rt_adapter(adapter)
        return false if adapter.blank?
        raise "Unknown adapter: #{adapter}!" unless %w(sqlite sqlite3 mysql postgresql).include?(adapter)
        # If adapter is sqlite or sqlite3, make sure that rt.db exists
        raise "#{rt_db_path} doesn't exist!" if %w(sqlite sqlite3).include?(adapter) && !File.exist?(rt_db_path)
        @@rt_adapter = adapter
      rescue Exception => e
        puts e
        return false
      end

      def self.set_rt_db_host(host)
        return nil if host.blank?
        @@rt_db_host = host
      end

      def self.set_rt_db_port(port)
        return nil if port.to_i == 0
        @@rt_db_port = port.to_i
      end

      def self.set_rt_db_name(name)
        return nil if name.blank?
        @@rt_db_name = name
      end

      def self.set_rt_db_username(username)
        @@rt_db_username = username
      end

      def self.set_rt_db_password(password)
        @@rt_db_password = password
      end

      def self.set_rt_db_schema(schema)
        @@rt_db_schema = schema
      end

      mattr_reader :rt_directory, :rt_adapter, :rt_db_host, :rt_db_port, :rt_db_name, :rt_db_schema, :rt_db_username, :rt_db_password, :rt_queue

      def self.rt_db_path; "#{rt_directory}/db/rt.db" end
      def self.rt_attachments_directory; "#{rt_directory}/attachments" end
      
      
      # mapping active record classes to RT3
      class RTUsers < ActiveRecord::Base
        set_table_name :users
      end
      
      # create a mapping from standard RT3 elements to redmine
    
      # RT Queue ~= Redmine Project, possible multiple queues => one project with custom field
      ## Name = Name
      ## Description = Description
      ## InitialPriority
      ## FinalPriority
    
    
      # RT Ticket = Redmine Issues
    
    
      # RT Groups = Redmine Groups
    end #RTMigrate Module
    
    # lets make sure the user has a created database
#    puts
#    if Redmine::DefaultData::Loader.no_data?
#      puts "Redmine configuration need to be loaded before importing data."
#      puts "Please, run this first:"
#      puts
#      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
#      exit
#    else
#      puts "Redmine configuration found. Moving on."
#    end
    
    # give the user one last chance to quit
#    print "WARNING: Back up before doing this, are you sure you want to continue ? [y/N] "
#    STDOUT.flush
#    break unless STDIN.gets.match(/^y$/i)
#    puts
    
    # make one funciton for outputing a question and getting a response
    def prompt(text, options = {}, &block)
      default = options[:default] || ''
      while true
        print "#{text} [#{default}]: "
        STDOUT.flush
        value = STDIN.gets.chomp!
        value = default if value.blank?
        break if yield value
      end
    end # end def prompt
    
    DEFAULT_PORTS = {'mysql' => 3306, 'postgresql' => 5432}
    
    # uses def prompt for getting/setting values
    # Don't think I need the directory
    # prompt('RT directory', :default => '/opt/rt3') {|directory| RTMigrate.set_rt_directory directory.strip}
    prompt('RT database adapter (sqlite, sqlite3, mysql, postgresql)', :default => 'mysql') {|adapter| RTMigrate.set_rt_adapter adapter}
    unless %w(sqlite sqlite3).include?(RTMigrate.rt_adapter)
      # we need more info if it's not sqlite3
      prompt('RT database host', :default => 'localhost') {|host| RTMigrate.set_rt_db_host host}
      prompt('RT database port', :default => DEFAULT_PORTS[RTMigrate.rt_adapter]) {|port| RTMigrate.set_rt_db_port port}
      prompt('RT database name', :default => 'rt3') {|name| RTMigrate.set_rt_db_name name}
      prompt('RT database schema', :default => 'public') {|schema| RTMigrate.set_rt_db_schema schema}
      prompt('RT database username') {|username| RTMigrate.set_rt_db_username username}
      prompt('RT database password') {|password| RTMigrate.set_rt_db_password password}
    end
    prompt('RT database encoding', :default => 'UTF-8') {|encoding| RTMigrate.encoding encoding}
    prompt('RT queue name') {|queue| RTMigrate.set_rt_queue queue}
    prompt('Redmine target project identifier', :default => RTMigrate.get_rt_queue) {|identifier| RTMigrate.target_project_identifier identifier}
    puts
    
    # now lets do the migrate
    Setting.notified_events = [] # Turn off email notifications
    RTMigrate.migrate
  end
end