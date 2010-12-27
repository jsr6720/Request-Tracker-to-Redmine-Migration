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
require 'pp'

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
      rejected_status = IssueStatus.find :last, :conditions => { :is_closed => true }
      STATUS_MAPPING = {'new' => DEFAULT_STATUS,
                        'open' => assigned_status,
                        'stalled' => feedback_status,
                        'resolved' => closed_status,
                        'rejected' => rejected_status,
                        'deleted' => rejected_status # should get skipped over, but here if that code gets removed (ie migrate deleted tickets)
                        }
      
      
      PRIORITY_MAPPING = IssuePriority.all
      DEFAULT_PRIORITY = PRIORITY_MAPPING[0]

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
      reporter_role = roles[2]
      DEFAULT_ROLE = roles.last
      ROLE_MAPPING = {'admin' => manager_role,
                      'developer' => developer_role,
                      'reporter' => reporter_role
                      }
      
      # MAP RT Custom fields to Redmine custom fields
      CUSTOM_FIELD_MAPPING = { 'Select' => 'list'
                              }
      CUSTOM_FIELD_MAPPING.default = 'string' # if not found default to string type
      
      # utillity class
      class ::Time
        class << self
          alias :real_now :now
          def now
            real_now - @fake_diff.to_i
          end
          def fake(time)
            @fake_diff = real_now - time
            res = yield
            @fake_diff = 0
           res
          end
        end
      end
      
      # entry point for migrate script.
      def self.migrate
        establish_connection
        
        # quick DB test
        RTUsers.count # fails out if not connected properly
        
        # what are we migrating
        migrated_custom_values = 0
        migrated_tickets = 0
        migrated_ticket_attachments = 0
        
        puts 'migrating data'
        # lets do a transaction
        ActiveRecord::Base.transaction do
          
          # Plan of action (users added as-needed basis)
          # == transfer the basic stuff
          # * custom fields
          # ** available values
          # * Queues (map to projects)
          # ** Tickets (map to issues)
          # *** Convert transactions to messages
          # *** Extract attatchments to file system
          # *** RT links => Redmine issue_relations
          
          # Custom fields
          print "Migrating custom fields"
          custom_field_map = {}
          RTCustomFields.find_each do |field|
            print '.'
            STDOUT.flush
            # Redmine custom field name
            field_name = encode(field.Name[0, limit_for(IssueCustomField, 'name')]).humanize
            # Find if the custom already exists in Redmine
            f = IssueCustomField.find_by_name(field_name)
            # Or create a new one
            field_format = CUSTOM_FIELD_MAPPING[field.Type]
            
            f ||= IssueCustomField.create(:name => encode(field.Name[0, limit_for(IssueCustomField, 'name')]).humanize,
                                          :field_format => encode(field_format))
            
            # get possible values if list based
            if f.field_format.downcase == 'list'
              field.customfieldvalues.find_each do |field_value|
                f.possible_values = (f.possible_values + field_value.Name.scan(/^.*/)).flatten.compact.uniq
              end
            end
            
            next if f.new_record?
            f.trackers = Tracker.find(:all)
            f.projects << @target_project
            custom_field_map[field.Name] = f
          end
          puts
          
          # set an RT ticket id field as a Redmine issue custom field.
          r = IssueCustomField.find(:first, :conditions => { :name => "RT ID" })
          # make it a string so it's searchable only add if it's not found
          r ||= IssueCustomField.new(:name => 'RT ID',
                                   :field_format => 'string',
                                   :searchable => true,
                                   :is_filter => true) if r.nil?
          r.trackers = Tracker.find(:all)
          # only add it to a project if it was newly created
          if r.new_record?
            r.projects << @target_project
          end
          r.save!
          custom_field_map['RT ID'] = r
          ### end custom field
        
          # Tickets - migrate by queue
          RTQueues.find_each do |queue| # find_each
            next if queue.Name == '___Approvals' # we don't migrate this queue
            # get an identifier for the queue
            prompt('Redmine target project identifier for %s queue' % queue.Name, :default => queue.Name.downcase.dasherize.gsub(/[ ]/,'-')) {|identifier| RTMigrate.target_project_identifier identifier}
            
            print "Migrating tickets"
            queue.tickets.find_each do |ticket|
              next if ticket.Status == 'deleted' # we don't migrate deleted tickets
              print '.'
              STDOUT.flush
              
              # create the new issue
              i = Issue.new :project => @target_project,
                              :subject => encode(ticket.Subject[0, limit_for(Issue, 'subject')]),
                              :description => 'RT migrate, see first comment',
                              :priority => normalize_rt_priority(ticket.Priority) || DEFAULT_PRIORITY,
                              :created_on => ticket.Created
              
            #  puts ticket.transactions
              trans = ticket.transactions.find(:last, :conditions => ["ObjectType = ? and ObjectId = ? and Type = ? and Field = ?", 'RT::Ticket', ticket.id, 'AddWatcher', 'Requestor'])
              trans ||= ticket.transactions.find(:last, :conditions => ["ObjectType = ? and ObjectId = ? and Type = ?", 'RT::Ticket', ticket.id, 'Create'])
              i.author = find_or_create_user('') # requester
              i.status = STATUS_MAPPING[ticket.Status] || DEFAULT_STATUS
              
              # RT has no concept of a tracker. so default it
              i.tracker = TRACKER_MAPPING[ticket.type] || DEFAULT_TRACKER
              
              # if importing into a blank system this works
              i.id = ticket.id unless Issue.exists?(ticket.id)
              
              # @TODO set the custom field RT ID
              
              # we'll want to set this for some projects. ie Sub-Queue becomes Queue with 'Sub' category
              # i.category = issues_category_map[ticket.component] unless ticket.component.blank?
              
              next unless Time.fake(ticket.LastUpdated) { i.save }
              TICKET_MAP[ticket.id] = i.id
              migrated_tickets += 1
              
              # Owner
              unless ticket.Owner.blank?
                i.assigned_to = find_or_create_user('', true) # RTUsers.find_by_id(ticket.Owner).Name
                Time.fake(ticket.LastUpdated) { i.save }
              end
=begin

              # Comments and status/resolution changes
              ticket.changes.group_by(&:time).each do |time, changeset|
                  status_change = changeset.select {|change| change.field == 'status'}.first
                  resolution_change = changeset.select {|change| change.field == 'resolution'}.first
                  comment_change = changeset.select {|change| change.field == 'comment'}.first

                  n = Journal.new :notes => (comment_change ? convert_wiki_text(encode(comment_change.newvalue)) : ''),
                                  :created_on => time
                  n.user = find_or_create_user(changeset.first.author)
                  n.journalized = i
                  if status_change &&
                       STATUS_MAPPING[status_change.oldvalue] &&
                       STATUS_MAPPING[status_change.newvalue] &&
                       (STATUS_MAPPING[status_change.oldvalue] != STATUS_MAPPING[status_change.newvalue])
                    n.details << JournalDetail.new(:property => 'attr',
                                                   :prop_key => 'status_id',
                                                   :old_value => STATUS_MAPPING[status_change.oldvalue].id,
                                                   :value => STATUS_MAPPING[status_change.newvalue].id)
                  end
                  if resolution_change
                    n.details << JournalDetail.new(:property => 'cf',
                                                   :prop_key => custom_field_map['resolution'].id,
                                                   :old_value => resolution_change.oldvalue,
                                                   :value => resolution_change.newvalue)
                  end
                  n.save unless n.details.empty? && n.notes.blank?
              end

              # Attachments
              ticket.attachments.each do |attachment|
                next unless attachment.exist?
                  attachment.open {
                    a = Attachment.new :created_on => attachment.time
                    a.file = attachment
                    a.author = find_or_create_user(attachment.author)
                    a.container = i
                    a.description = attachment.description
                    migrated_ticket_attachments += 1 if a.save
                  }
              end

              # Custom fields
              custom_values = ticket.customs.inject({}) do |h, custom|
                if custom_field = custom_field_map[custom.name]
                  h[custom_field.id] = custom.value
                  migrated_custom_values += 1
                end
                h
              end
              if custom_field_map['resolution'] && !ticket.resolution.blank?
                custom_values[custom_field_map['resolution'].id] = ticket.resolution
              end
              i.custom_field_values = custom_values
              i.save_custom_field_values
=end
            end # end ticket migration
            
            # update issue id sequence if needed (postgresql)
            Issue.connection.reset_pk_sequence!(Issue.table_name) if Issue.connection.respond_to?('reset_pk_sequence!')
            puts
          end # end queue migrate
        
        end # end transaction
        puts 'complete'
        
      end ### end self.migrate
      
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
      
      # this allows going to the data source via Redmine models
      # and getting the string length limit as set by database
      # ie: limit_for(User, 'mail')
      #     => 60
      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end
      
      # encode to make sure we have good data
      def self.encoding(charset)
        @ic = Iconv.new('UTF-8', charset)
      rescue Iconv::InvalidEncoding
        puts "Invalid encoding!"
        return false
      end
      
      # normlize integer based priorities with redmine contex based priorities
      def self.normalize_rt_priority(priority)
        # @TODO take the initial priority, final pirority and current priority
        # => normalize into a 0-5 value
        
        # 'low' => priorities[0],
        # 'normal' => priorities[1],
        # 'high' => priorities[2],
        # 'urgent' => priorities[3],
        # 'immediate' => priorities[4]
        
        # just return a normal for now
        PRIORITY_MAPPING[1]
      end
      
      # Following are get/set for user collected prompts
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
      
      # when migrating tickets and other RT data lets create members if needed
      def self.find_or_create_user(username, project_member = false)
        return User.anonymous if username.blank?
        
        # search redmine for this user
        u = User.find_by_login(username)
        if !u
          # Create a new user if not found
          mail = username[0,limit_for(User, 'mail')]
          if mail_attr = RTUsers.find_by_Name(username)
            mail = mail_attr.value
          end
          mail = "#{mail}@foo.bar" unless mail.include?("@")

          name = username
          if name_attr = RTUsers.find_by_Name(username)
            name = name_attr.value
          end
          name =~ (/(.*)(\s+\w+)?/)
          fn = $1.strip
          ln = ($2 || '-').strip

          u = User.new :mail => mail.gsub(/[^-@a-z0-9\.]/i, '-'),
                       :firstname => fn[0, limit_for(User, 'firstname')].gsub(/[^\w\s\'\-]/i, '-'),
                       :lastname => ln[0, limit_for(User, 'lastname')].gsub(/[^\w\s\'\-]/i, '-')

          u.login = username[0,limit_for(User, 'login')].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = 'rt_user'
          # RT permissions not boiled down to one action
          # u.admin = true if TracPermission.find_by_username_and_action(username, 'admin')
          
          # finally, a default user is used if the new user is not valid
          u = User.find(:first) unless u.save
        end
        # Make sure he is a member of the project
        if project_member && !u.member_of?(@target_project)
          # RT role mapping not great, so just make them a reporter
          role = ROLE_MAPPING['reporter']
          
          Member.create(:user => u, :project => @target_project, :roles => [role])
          u.reload
        end
        u
      end # end find_or_create_user
      
      # mapping active record classes to RT3
      class RTUsers < ActiveRecord::Base
        set_table_name :users
      end
      
      # RT's concept of custom fields
      class RTCustomFields < ActiveRecord::Base
        set_table_name :customfields
        
        has_many :customfieldvalues, :class_name => "RTCustomFieldValues", :foreign_key => :CustomField
      end
      
      # each custom field has a list of values
      class RTCustomFieldValues < ActiveRecord::Base
        set_table_name :customfieldvalues
        
        belongs_to :rtcustomfields # foreign key - CustomField
      end
      
      # RT Queue ~= Redmine Project
      class RTQueues < ActiveRecord::Base
        set_table_name :queues
        
        has_many :tickets, :class_name => "RTTickets", :foreign_key => :Queue
      end
      
      # RT Ticket = Redmine issue
      # RT does not have a concept of tracker, so all tickets are of one type
      class RTTickets < ActiveRecord::Base
        set_table_name :tickets
        
        belongs_to :rtqueues
        has_many :transactions, :class_name => "RTTransactions", :foreign_key => :ObjectId
      end
      
      # all actions in RT tracked via transactions
      # transactions have attachemnts
      class RTTransactions < ActiveRecord::Base
        set_table_name :transactions
        
        # that is to say there are ticket transactions here was well as many others
        belongs_to :rttickets, :polymorphic => true
        has_many :attachments, :class_name => "RTAttachments", :foreign_key => :TransactionId
      end
      
      # RT attachemnts is not just files, but also content
      class RTAttachments < ActiveRecord::Base
        set_table_name :attachments
        
        belongs_to :rttransactions # foreign key TransactionId
      end
      
      # used in RT simliar to Redmine related/duplicates
      class RTLinks < ActiveRecord::Base
        set_table_name :links
      end
    
      # encode to proper standard
      private
        def self.encode(text)
          @ic.iconv text
        rescue
          text
        end
    end #RTMigrate Module
    
    # lets make sure the user has a created database
    puts
    if Redmine::DefaultData::Loader.no_data?
      puts "Redmine configuration need to be loaded before importing data."
      puts "Please, run this first:"
      puts
      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    else
      puts "Redmine configuration found. Moving on."
    end
    
    # give the user one last chance to quit
    print "WARNING: Back up before doing this, are you sure you want to continue ? [y/N] "
    STDOUT.flush
    break unless STDIN.gets.match(/^y$/i)
    puts
    
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
      prompt('RT database username', :default => 'rt') {|username| RTMigrate.set_rt_db_username username}
      prompt('RT database password') {|password| RTMigrate.set_rt_db_password password}
    end
    prompt('RT database encoding', :default => 'UTF-8') {|encoding| RTMigrate.encoding encoding}
    prompt('RT queue name', :default => 'general') {|queue| RTMigrate.set_rt_queue queue}
    prompt('Redmine target project identifier', :default => RTMigrate.get_rt_queue) {|identifier| RTMigrate.target_project_identifier identifier}
    puts
    
    # now lets do the migrate
    Setting.notified_events = [] # Turn off email notifications
    RTMigrate.migrate
  end
end