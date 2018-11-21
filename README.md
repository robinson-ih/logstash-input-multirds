# Logstash Input Multi-RDS

Forked from discourse/logstash-input-rds I needed competing consumer and multi-db support 
    input {
      rds {
        region => "us-west-2"
        instance_name_pattern => ".*"
        log_file_name_pattern => ".*"
        group_name => "rds"
      }
    }
