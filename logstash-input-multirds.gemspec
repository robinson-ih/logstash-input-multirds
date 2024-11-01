Gem::Specification.new do |s|
  s.name          = 'logstash-input-multirds'
  s.version       = '0.1.2'
  s.summary       = 'Ingest RDS log files to Logstash with competing consumers and multiple databases'

  s.authors       = ['Robert Labrie']
  s.email         = ['robert.labrie@gmail.com']
  s.homepage      = 'https://github.com/robertlabrie/logstash-input-multi-rds'

  s.require_paths = ['lib']
  s.files = Dir['lib/**/*', 'spec/**/*', 'vendor/**/*', '*.gemspec', '*.md', 'CONTRIBUTORS', 'Gemfile', 'LICENSE', 'NOTICE.TXT']
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { 'logstash_plugin' => 'true', 'logstash_group' => 'input' }

  # Gem dependencies
  s.add_runtime_dependency 'logstash-codec-plain'
  s.add_runtime_dependency 'logstash-core-plugin-api', '>= 2.1.12', '<= 2.99'
  s.add_runtime_dependency 'logstash-integration-aws'
  s.add_runtime_dependency 'stud', '>= 0.0.22'
  s.add_development_dependency 'logstash-devutils'
end
