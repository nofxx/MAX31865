lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'max31865/version'

Gem::Specification.new do |spec|
  spec.name          = 'max31865'
  spec.version       = MAX31865::VERSION
  spec.authors       = ['Marcos Piccinini']
  spec.email         = ['x@nofxx.com']

  spec.summary       = %q{Read temperatures from MAX31865 Thermocouple.}
  spec.description   = %q{PiPiper based wrapper for MAX31865 SPI Interface.}
  spec.homepage      = 'https://github.com/nofxx/max31865'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'pi_piper', '~> 2.0'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec', '~> 3'
end
