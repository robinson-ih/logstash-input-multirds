# Logstash Input Multi-RDS

Inputs RDS logs because Postgres doesn't support cloudwatch. Forked from discourse/logstash-input-rds I needed competing consumer and multi-db support. Uses DynamoDB for distributed locking and marker tracking. The plugin will create the table automatically if you give it permission, otherwise you can create it yourself where the table name is `group_name` and the primary key is a string called `id`.
```
    input {
      multirds {
        region => "us-east-1"
        instance_name_pattern => ".*"
        log_file_name_pattern => ".*"
        group_name => "rds"

      }
    }
```

## Configuration

* `region`: The AWS region for RDS. The AWS SDK reads this info from the usual places, so it's not required, but if you don't set it somewhere the plugin won't run
  * **required**: false

* `instance_name_pattern`: A regex pattern of RDS instances from which logs will be consumed
  * **required**: false
  * **default value**: `.*`

* `log_file_name_pattern`: A regex pattern of RDS log files to consume
  * **required**: false
  * **default value**: `.*`

* `group_name`: A unique identifier for all the instances of logstash which will be consuming this instance and log file pattern. Used for the lock table name.
  * **required**: true

* `client_id`: A unique identifier for a particular instance of logstash in the cluster
  * **required**: false
  * **default value**: `<hostname>:<uuid>`
