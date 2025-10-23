module RailsERD
  class Domain
    # Entities represent Ruby classes in your application.
    class Entity
      class << self
        def from_parsed_class(parsed, domain)
          new(domain, parsed)
        end
      end

      extend Inspectable
      inspection_attributes :name

      # The domain in which this entity resides.
      attr_reader :domain

      # The parsed class data.
      attr_reader :parsed_class

      # The name of this entity (the class name).
      attr_reader :name

      def initialize(domain, parsed) # @private :nodoc:
        @domain = domain
        @parsed_class = parsed
        @name = parsed[:class_name]
      end

      # Returns an array of attributes (methods) for this entity.
      def attributes
        @attributes ||= parsed_class[:public_methods].map do |method_data|
          Attribute.new(self, method_data)
        end
      end

      # Returns an array of all relationships that this entity has with other
      # entities in the domain model.
      def relationships
        domain.relationships_by_entity_name(name)
      end

      # Returns +true+ if this entity has any relationships with other classes,
      # +false+ otherwise.
      def connected?
        relationships.any?
      end

      # Returns +true+ if this entity has no relationships with any other classes,
      # +false+ otherwise. Opposite of +connected?+.
      def disconnected?
        relationships.none?
      end

      # Returns +true+ if this entity is a framework base class.
      def generalized?
        # Mark framework base classes as generalized
        %w[ApplicationRecord ApplicationController ApplicationMailer ApplicationJob
           ActionController::Base ActiveRecord::Base ActionMailer::Base ActiveJob::Base
           Object BasicObject].include?(name)
      end

      # Returns +true+ if this entity has a superclass.
      def specialized?
        !parsed_class[:superclass].nil?
      end

      # Returns +true+ if this is a framework class.
      def virtual?
        generalized?
      end
      alias_method :abstract?, :virtual?

      # Returns all child entities, if this entity has any.
      def children
        @children ||= domain.specializations_by_entity_name(name).map(&:specialized)
      end

      def namespace
        $1 if name.match(/(.*)::.*/)
      end

      def ==(other)
        other.is_a?(Entity) && other.name == name
      end

      def to_s # @private :nodoc:
        name
      end

      def <=>(other) # @private :nodoc:
        self.name <=> other.name
      end
    end
  end
end
