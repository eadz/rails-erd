require "rails_erd"
require "rails_erd/domain/attribute"
require "rails_erd/domain/entity"
require "rails_erd/domain/relationship"
require "rails_erd/domain/specialization"
require "rails_erd/domain/ruby_parser"
require "rails_erd/domain/static_analyzer"

module RailsERD
  # The domain describes your Rails domain model. This class is the starting
  # point to get information about your models.
  #
  # === Options
  #
  # The following options are available:
  #
  # warn:: When set to +false+, no warnings are printed to the
  #        command line while processing the domain model. Defaults
  #        to +true+.
  class Domain
    class << self
      # Generates a domain model object based on Ruby files in app/ and lib/ directories.
      #
      # The +options+ hash allows you to override the default options. For a
      # list of available options, see RailsERD.
      def generate(options = {})
        # Determine which directories to scan
        root_path = options[:root] || Dir.pwd
        scan_paths = if options[:paths]
          options[:paths].map { |p| File.join(root_path, p) }
        else
          [
            File.join(root_path, 'app'),
            File.join(root_path, 'lib')
          ].select { |p| Dir.exist?(p) }
        end

        # Discover all Ruby files
        ruby_files = discover_ruby_files(scan_paths)

        # Parse each file
        parsed_classes = []
        ruby_files.each do |file_path|
          result = RubyParser.parse_file(file_path)
          if result && result[:class_name]
            result[:file_path] = file_path
            parsed_classes << result
          end
        end

        new(parsed_classes, options)
      end

      # Discover all Ruby files in specified directories
      def discover_ruby_files(paths)
        paths.flat_map do |path|
          if File.directory?(path)
            Dir.glob(File.join(path, '**', '*.rb'))
          elsif File.exist?(path)
            [path]
          else
            []
          end
        end.uniq.sort
      end
    end

    extend Inspectable
    inspection_attributes

    # The options that are used to generate this domain model.
    attr_reader :options

    # Create a new domain model object based on the given array of parsed classes.
    def initialize(parsed_classes = [], options = {})
      @parsed_classes = parsed_classes
      @options = RailsERD.options.merge(options)
      @entities = []
      @relationships = []
      @specializations = []

      process_parsed_classes
    end

    # Returns the domain model name, which is the name of your Rails
    # application or +nil+ outside of Rails.
    def name
      return unless defined?(Rails) && Rails.application

      if Rails.application.class.respond_to?(:module_parent)
        Rails.application.class.module_parent.name
      else
        Rails.application.class.parent.name
      end
    end

    # Returns all entities of your domain model.
    def entities
      @entities
    end

    # Returns all relationships in your domain model.
    def relationships
      @relationships
    end

    # Returns all specializations in your domain model.
    def specializations
      @specializations
    end

    # Returns a specific entity object for the given Active Record model.
    def entity_by_name(name) # @private :nodoc:
      entity_mapping[name]
    end

    # Returns an array of relationships for the given Active Record model.
    def relationships_by_entity_name(name) # @private :nodoc:
      relationships_mapping[name] or []
    end

    def specializations_by_entity_name(name)
      specializations_mapping[name] or []
    end

    def warn(message) # @private :nodoc:
      puts "Warning: #{message}" if options.warn
    end

    private

    def process_parsed_classes
      # Create entities from parsed classes
      @parsed_classes.each do |parsed|
        entity = Entity.from_parsed_class(parsed, self)
        @entities << entity if entity
      end

      # Create specializations (inheritance)
      @parsed_classes.each do |parsed|
        next unless parsed[:superclass]

        source = @entities.find { |e| e.name == parsed[:class_name] }
        target = @entities.find { |e| e.name == parsed[:superclass] }

        if source && target
          @specializations << Specialization.new(self, source, target)
        end
      end

      # Create relationships (method calls)
      @parsed_classes.each do |parsed|
        source_entity = @entities.find { |e| e.name == parsed[:class_name] }
        next unless source_entity

        # Read the file and analyze method calls
        source_code = File.read(parsed[:file_path])
        calls = StaticAnalyzer.find_method_calls(source_code)

        calls.each do |call|
          target_entity = @entities.find { |e| e.name == call[:target_class] }
          next unless target_entity

          # Check if we already have this relationship
          existing = @relationships.find do |r|
            r.source == source_entity && r.destination == target_entity
          end

          unless existing
            @relationships << Relationship.from_method_call(self, source_entity, target_entity)
          end
        end
      end
    end

    def entity_mapping
      @entity_mapping ||= {}.tap do |mapping|
        entities.each do |entity|
          mapping[entity.name] = entity
        end
      end
    end

    def relationships_mapping
      @relationships_mapping ||= {}.tap do |mapping|
        relationships.each do |relationship|
          (mapping[relationship.source.name] ||= []) << relationship
          (mapping[relationship.destination.name] ||= []) << relationship
        end
      end
    end

    def specializations_mapping
      @specializations_mapping ||= {}.tap do |mapping|
        specializations.each do |specialization|
          (mapping[specialization.generalized.name] ||= []) << specialization
          (mapping[specialization.specialized.name] ||= []) << specialization
        end
      end
    end

  end
end
