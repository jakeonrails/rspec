# frozen_string_literal: true

source "https://gem.coop"

%w[rspec rspec-core rspec-expectations rspec-mocks rspec-support].each do |lib|
  gem lib, :path => File.expand_path("../#{lib}", __FILE__)
end

group :coverage do
  gem 'simplecov'
end

### deps for rdoc.info
group :documentation do
  gem 'github-markup', :platform => :mri
  gem 'redcarpet', :platform => :mri
  # Webrick extracted from Ruby 3.0.0, required by Yard
  gem 'webrick', '~> 1.9.1', :require => false
  gem 'yard', '~> 0.9.24', :require => false
end

#
# Support for gems extracted in Ruby versions
#

gem 'bigdecimal', :require => false if RUBY_VERSION.to_f >= 3.3
gem 'drb' if RUBY_VERSION.to_f >= 3.3
gem 'tsort', '0.1.0' if RUBY_VERSION.to_f < 3.1

#
# Tooling / our testing
#

gem 'aruba', '>= 2.3.3', '< 3.0.0'
gem 'coderay' # syntax highlighting
gem 'rake', '>= 13.0.0'
# On Ruby >= 3.2 aruba 2.4 pulls in irb -> rdoc, and rdoc 8 depends on rbs,
# whose native extension does not build on JRuby. Keep rdoc 7 there.
gem 'rdoc', '< 8', :require => false if RUBY_ENGINE == 'jruby'
gem "thread_order", "~> 1.1.0"

# No need to run rubocop on earlier versions
gem "rubocop", "~> 1.80" if RUBY_VERSION >= '3.3' && RUBY_ENGINE == 'ruby'

#
# Other test tools for integration tests
#

gem 'flexmock', '~> 0.9.0'
gem 'minitest', '~> 5.15'
gem 'mocha', '~> 0.13.0'
gem 'rr', "~> 1.0.4"
gem 'test-unit', '~> 3.0'

eval File.read('Gemfile-custom') if File.exist?('Gemfile-custom')
