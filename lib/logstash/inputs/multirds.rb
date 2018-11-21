# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "aws-sdk"
require "logstash/inputs/multirds/patch"
require "logstash/plugin_mixins/aws_config"
require "time"
require "socket"
Aws.eager_autoload!

class LogStash::Inputs::Multirds < LogStash::Inputs::Base
  include LogStash::PluginMixins::AwsConfig::V2

  config_name "multirds"
  milestone 1
  default :codec, "plain"

  config :instance_name_pattern, :validate => :string, :default => '.*'
  config :log_file_name_pattern, :validate => :string, :default => '.*'
  config :polling_frequency, :validate => :number, :default => 600
  config :group_name, :validate => :string, :required => true
  config :client_id, :validate => :string
  
  def ensure_lock_table(db, table)
    begin
        tables = db.list_tables({

        })
        return true if tables.to_h[:table_names].to_a.include?(table)
        # TODO: there is a potential race condition here where a table could come back in list_tables but not be in ACTIVE state we should check this better
        result = db.create_table({
            table_name: table,
            key_schema: [
                {
                    attribute_name: 'id',
                    key_type: 'HASH'
                }
            ],
            attribute_definitions: [
                {
                    attribute_name: 'id',
                    attribute_type: 'S'
                }
            ],
            provisioned_throughput: {
                read_capacity_units: 10,
                write_capacity_units: 10
            }
        })

        # wait here for the table to be ready
        (1..10).each do |i|
            sleep i
            rsp = db.describe_table({
                table_name: table
            })
            return true if rsp.to_h[:table][:table_status] == 'ACTIVE'
        end
    rescue => e
        @logger.error "logstash-input-multirds ensure_lock_table exception\n #{e}"
        return false
    end
    return false
  end
  def acquire_lock(db, table, id, lock_owner, expire_time: 10)
    begin
        db.update_item({
            key: {
                id: id
            },
            table_name: table,
            update_expression: "SET lock_owner = :lock_owner, expires = :expires",
            expression_attribute_values: {
                ':lock_owner' => lock_owner,
                ':expires' =>  Time.now.utc.to_i + expire_time
            },
            return_values: "UPDATED_NEW",
            condition_expression: "attribute_not_exists(lock_owner) OR lock_owner = :lock_owner OR expires < :expires"
        })
    rescue => e
      @logger.error "logstash-input-multirds acquire_lock exception\n #{e}"
    end
  end
  def get_logfile_list(rds, instance_pattern, logfile_pattern)
    log_files = []
    begin
      dbs = rds.describe_db_instances
      dbs.to_h[:db_instances].each do |db|
          next unless db[:db_instance_identifier] =~ /#{instance_pattern}/
          logs = rds.describe_db_log_files({
              db_instance_identifier: db[:db_instance_identifier]
          })

          logs.to_h[:describe_db_log_files].each do |log|
              next unless log[:log_file_name] =~ /#{logfile_pattern}/
              log[:db_instance_identifier] = db[:db_instance_identifier]
              log_files.push(log)
          end
      end
    rescue => e
      @logger.error "logstash-input-multirds get_logfile_list instance_pattern: #{instance_pattern} logfile_pattern:#{logfile_pattern} exception \n#{e}"
    end
    log_files
end
def get_logfile_record(db, id, tablename)
  res = db.get_item({
      key: {
          id: id
      },
      table_name: tablename
  })
  extra_fields = {'marker' => '0:0'}
  extra_fields.merge(res.item)
end
def set_logfile_record(db, id, tablename, key, value)
  db.update_item({
      key: {
          id: id
      },
      table_name: tablename,
      update_expression: "SET #{key} = :v",
      expression_attribute_values: {
          ':v' => value
      },
      return_values: "UPDATED_NEW"
  
  })
end

  def register
    @client_id = "#{Socket.gethostname}:#{java.util::UUID.randomUUID.to_s}" unless @client_id
    @logger.info "Registering multi-rds input", :instance_name_pattern => @instance_name_pattern, :log_file_name_pattern => @log_file_name_pattern, :group_name => @group_name, :region => @region, :client_id => @client_id

    @db = Aws::DynamoDB::Client.new aws_options_hash
    @rds = Aws::RDS::Client.new aws_options_hash

    @ready = ensure_lock_table @db, @group_name
  end

  def run(queue)
    if !@ready
      @logger.warn "multi-rds dynamodb lock table not ready, unable to proceed"
      return false
    end
    @thread = Thread.current
    Stud.interval(@polling_frequency) do
      logs = get_logfile_list @rds, @instance_name_pattern, @log_file_name_pattern

      logs.each do |log|
        id = "#{log[:db_instance_identifier]}:#{log[:log_file_name]}"
        lock = acquire_lock @db, @group_name, id, @client_id
        next unless lock # we won't do anything with the data unless we get a lock on the file
        
        rec = get_logfile_record @db, id, @group_name
        next unless rec['marker'].split(':')[1].to_i < log[:size].to_i # No new data in the log file so just continue

        # start reading log data at the marker
        more = true
        marker = rec[:marker]
        while more do
            rsp = @rds.download_db_log_file_portion(
                db_instance_identifier: log[:db_instance_identifier],
                log_file_name: log[:log_file_name],
                marker: rec[:marker],
            )
            rsp[:log_file_data].lines.each do |line|
              @codec.decode(line) do |event|
                decorate event
                event.set "rds_instance", log[:db_instance_identifier]
                event.set "log_file", log[:log_file_name]
                queue << event
              end
            end
            more = rsp[:additional_data_pending]
            marker = rsp[:marker] 
        end
        # set the marker back in the lock table
        set_logfile_record @db, id, @group_name, 'marker', marker
      end
    end

  end

  def stop
    Stud.stop! @thread
  end

  def filename2datetime(name)
    parts = name.match /(\d{4})-(\d{2})-(\d{2})-(\d{2})$/
    Time.utc parts[1], parts[2], parts[3], parts[4]
  end

  private
  module SinceDB
    class File
      def initialize(file)
        @db = file
      end

      def read
        if ::File.exists?(@db)
          content = ::File.read(@db).chomp.strip
          return content.empty? ? Time.new : Time.parse(content)
        else
          return Time.new("1999-01-01")
        end
      end

      def write(time)
        ::File.open(@db, 'w') { |file| file.write time.to_s }
      end
    end
  end
end
